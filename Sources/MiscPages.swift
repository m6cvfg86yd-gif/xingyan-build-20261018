import SwiftUI

/* ============================================================ 收藏 */

struct FavoritesView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var items: [[String: Any]] = []
    @State private var loading = true
    @State private var viewerPaths: [String] = []
    @State private var viewerIndex: Int?
    /* 微信收藏页顶部：搜索框 + 类型筛选 */
    @State private var q = ""
    @State private var kindFilter = "all"
    /// 右上角「＋」：写一条笔记（纯文字，存进收藏，kind = text）
    @State private var showCompose = false
    /// 点开的那条文字收藏（详情：全文 / 复制 / 编辑 / 删除）
    @State private var noteDetail: [String: Any]? = nil
    /// 「＋」菜单（微信那种：写笔记 / 拍照 / 从相册选择）
    @State private var showAddMenu = false
    @State private var showTakePhoto = false
    @State private var showPickPhoto = false
    @State private var savingImage = false
    /// 要转发的那条（选完人由 ForwardPickerView 发出去）
    @State private var forward: [ForwardItem] = []
    @State private var showForward = false

    private var shown: [[String: Any]] {
        let key = q.trimmingCharacters(in: .whitespaces)
        return items.filter { it in
            let kind = (it["kind"] as? String) ?? "text"
            /* 「图片与视频」把九宫格（images）、视频、实况也算进去（以前只认单张 image，
               从聊天里收藏的九宫格在"图片"这一栏里根本看不到） */
            let isPic = ["image", "images", "video", "livephoto"].contains(kind)
            if kindFilter == "image" && !isPic { return false }
            if kindFilter == "text" && isPic { return false }
            if key.isEmpty { return true }
            /* 搜索按微信那套：正文、标题、来源都算；再宽一点 ——
               打「图片 / 视频 / 转账 / 笔记」这种类型词也能把对应的挑出来 */
            let content = (it["content"] as? String) ?? ""
            let title = (it["title"] as? String) ?? ""
            let from = (it["fromName"] as? String) ?? ""
            if content.localizedCaseInsensitiveContains(key) { return true }
            if title.localizedCaseInsensitiveContains(key) { return true }
            if from.localizedCaseInsensitiveContains(key) { return true }
            let typeWords: [String] = isPic ? [Tr("图片"), Tr("视频"), Tr("照片")]
                                        : (kind == "transfer" ? [Tr("转账")] : [Tr("文字"), Tr("笔记")])
            return typeWords.contains { $0.localizedCaseInsensitiveContains(key) }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium))
                    .foregroundColor(C.searchIcon)
                TextField(Tr("搜索收藏"), text: $q)
                    .font(pf(14.5))
                if !q.isEmpty {
                    Button { q = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                            .foregroundColor(C.searchIcon)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(C.searchBg))
            .padding(.horizontal, 8)
            .padding(.top, 8)

            HStack(spacing: 8) {
                chip(Tr("全部"), "all")
                chip(Tr("图片与视频"), "image")
                chip(Tr("文字"), "text")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .background(C.pageBg)
    }

    private func chip(_ title: String, _ key: String) -> some View {
        let on = (kindFilter == key)
        return Button { kindFilter = key } label: {
            Text(title)
                .font(pf(13.5))
                .foregroundColor(on ? .white : C.subLabel)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(on ? C.green : C.cardBg))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("收藏"), back: { dismiss() }) {
                /* 和微信收藏一样：右上角一颗「＋」，点开就能写一条笔记 */
                Button { showAddMenu = true } label: {
                    if savingImage {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(C.label)
                        .frame(width: 40, height: 32)
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
            }
            header
            List {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                        .listRowBackground(C.cardBg)
                } else if items.isEmpty {
                    Text(Tr("还没有收藏。聊天里长按消息「收藏」会出现在这里，右上角「＋」可以自己写笔记。"))
                        .font(pf(14))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .listRowBackground(C.cardBg)
                }
                ForEach(shown.indices, id: \.self) { i in
                    let item = shown[i]
                    let kind = (item["kind"] as? String) ?? "text"
                    let content = (item["content"] as? String) ?? ""
                    HStack(spacing: 12) {
                        if let thumb = thumbOf(item) {
                            /* 图片收藏（单张）和从聊天里收藏的「九宫格」都出缩略图 ——
                               以前九宫格那种（kind=images）会把一整段 JSON 当正文显示出来 */
                            RemoteImage(path: thumb)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { openPhoto(thumb) }
                        }
                        if kind == "text" || kind == "transfer" {
                            /* 文字收藏（聊天里收藏的和自己写的笔记都算）：点一下进详情，
                               在那儿能复制 / 编辑 / 删除 */
                            Button { noteDetail = item } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        if (item["pinned"] as? Bool) == true {
                                            Image(systemName: "pin.fill")
                                                .font(.system(size: 11)).foregroundColor(C.green)
                                        }
                                        if let t = item["title"] as? String, !t.isEmpty {
                                            Text(t).font(pf(15.5, .medium)).foregroundColor(C.label)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    Text(previewText(content))
                                        .font(pf(15))
                                        .foregroundColor(C.label)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else if kind == "images" {
                            /* 九宫格收藏：右边一句「N 张图片」（微信也是这么标的） */
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Tr("［图片］")).font(pf(15)).foregroundColor(C.label)
                                Text(String(countImages(item)) + Tr(" 张图片"))
                                    .font(pf(12.5)).foregroundColor(C.subLabel)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    /* 每一条收藏都单独是一张小卡片（用户要求：行与行之间用小卡片隔开）——
                       灰底上白卡 + 8pt 间距，不再是原来那种一条到底的白列表。 */
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(C.cardBg))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    /* 微信收藏是**左滑出「删除」**（右滑不管用），全滑到底就直接删。
                       以前只有长按菜单，很多人根本不知道能删 —— 用户反馈的
                       「收藏里的东西没有删除」就是这个。 */
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if let fid = item["id"] as? String {
                            Button(role: .destructive) {
                                Task {
                                    await API.shared.deleteFavorite(fid)
                                    await load()
                                }
                            } label: {
                                Label(Tr("删除"), systemImage: "trash")
                            }
                            Button {
                                let on = ((item["pinned"] as? Bool) != true)
                                Task {
                                    _ = await API.shared.updateFavorite(id: fid, pinned: on)
                                    await load()
                                }
                            } label: {
                                Label((item["pinned"] as? Bool) == true ? Tr("取消置顶") : Tr("置顶"),
                                      systemImage: (item["pinned"] as? Bool) == true ? "pin.slash" : "pin")
                            }
                            .tint(C.orange)
                        }
                    }
                    /* 长按（微信收藏是长按出菜单）：置顶 / 删除 */
                    .contextMenu {
                        if let i = item["id"] as? String {
                            /* 转发给朋友（微信收藏长按第一项就是这个）—— 用户要求「要可以转发」 */
                            Button {
                                forward = forwardItems(of: item)
                                showForward = true
                            } label: {
                                Label(Tr("转发给朋友"), systemImage: "arrowshape.turn.up.right")
                            }
                            Button {
                                let on = ((item["pinned"] as? Bool) != true)
                                Task {
                                    _ = await API.shared.updateFavorite(id: i, pinned: on)
                                    await load()
                                }
                            } label: {
                                Label((item["pinned"] as? Bool) == true ? Tr("取消置顶") : Tr("置顶"),
                                      systemImage: (item["pinned"] as? Bool) == true ? "pin.slash" : "pin")
                            }
                            Button(role: .destructive) {
                                Task {
                                    await API.shared.deleteFavorite(i)
                                    await load()
                                }
                            } label: {
                                Label(Tr("删除"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .background(C.cardBg)
            .refreshable { await load() }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        /* 右上角「＋」：写一条笔记（这一层以前忘了挂，所以点了没反应 —— 2026-10-12 补上） */
        .sheet(isPresented: $showCompose) {
            FavoriteNoteComposeSheet { Task { await load() } }
                .environmentObject(app)
        }
        /* 「＋」菜单：写笔记 / 拍照 / 从相册选择（微信收藏就是这三项） */
        .confirmationDialog(Tr("添加收藏"), isPresented: $showAddMenu, titleVisibility: .hidden) {
            Button(Tr("写笔记")) { showCompose = true }
            Button(Tr("拍照")) { showTakePhoto = true }
            Button(Tr("从相册选择")) { showPickPhoto = true }
            Button(Tr("取消"), role: .cancel) { }
        }
        .fullScreenCover(isPresented: $showTakePhoto) {
            CameraPicker { img in saveImage(img) }
        }
        .sheet(isPresented: $showPickPhoto) {
            PhotoPicker { img in saveImage(img) }
        }
        /* 点开一条文字收藏 = 笔记详情（全文 / 复制 / 编辑 / 删除） */
        .sheet(isPresented: Binding(get: { noteDetail != nil },
                                    set: { if !$0 { noteDetail = nil } })) {
            if let it = noteDetail {
                FavoriteNoteDetailSheet(id: (it["id"] as? String) ?? "",
                                        content: (it["content"] as? String) ?? "",
                                        pinned: (it["pinned"] as? Bool) == true) {
                    Task { await load() }
                }
                .environmentObject(app)
            }
        }
        /* 转发给朋友：走聊天那套「先选一个聊天」 */
        .sheet(isPresented: $showForward) {
            ForwardPickerView(items: forward) { }
                .environmentObject(app)
        }
        .overlay {
            if let i = viewerIndex, !viewerPaths.isEmpty {
                /* 收藏里的图：一样给「转发 / 保存」 */
                PhotoPager(paths: viewerPaths, startIndex: i, showActions: true) { viewerIndex = nil }
            }
        }
    }

    /// 收藏里的图片也能点开看大图
    private func openPhoto(_ path: String) {
        let all = items.filter { (($0["kind"] as? String) ?? "") == "image" }
            .compactMap { $0["content"] as? String }
        guard !all.isEmpty else { return }
        viewerPaths = all
        viewerIndex = all.firstIndex(of: path) ?? 0
    }

    /// 一条收藏要转发时，按类型包成聊天消息：
    /// · 图片 / 九宫格 → 原样当图片发（对面收到的是图，不是一串路径）
    /// · 笔记（文字，里面可能有 [图]路径）→ kind = note，对面收到的是**笔记卡片**
    ///   （以前按 text 发，对面看到的是一大段带 [图]路径 的"代码"）
    /// · 转账那种摘要 → 当普通文字发
    private func forwardItems(of item: [String: Any]) -> [ForwardItem] {
        let kind = (item["kind"] as? String) ?? "text"
        let content = (item["content"] as? String) ?? ""
        switch kind {
        case "image":
            return [ForwardItem(kind: "image", content: content)]
        case "images":
            return [ForwardItem(kind: "images", content: content)]
        case "video":
            return [ForwardItem(kind: "video", content: content)]
        case "livephoto":
            return [ForwardItem(kind: "livephoto", content: content)]
        case "transfer":
            return [ForwardItem(kind: "text", content: content)]
        default:
            /* 笔记：有图就当笔记卡片发，纯文字直接当文字发（对面不用再点开） */
            let hasPic = content.components(separatedBy: "\n").contains { $0.hasPrefix("[图]") }
            return [ForwardItem(kind: hasPic ? "note" : "text", content: content)]
        }
    }

    /// 收藏里那条是图片的话，取一张缩略图出来（九宫格取第一张）；
    /// 不是图片就返回 nil。以前只认 kind == "image"，从聊天里收藏的九宫格
    /// 会被当成文字，把一整段 JSON 显示出来。
    private func thumbOf(_ item: [String: Any]) -> String? {
        let kind = (item["kind"] as? String) ?? "text"
        let content = (item["content"] as? String) ?? ""
        if kind == "image" { return content.isEmpty ? nil : content }
        if kind == "images" {
            guard let d = content.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let paths = o["paths"] as? [String],
                  let first = paths.first, !first.isEmpty else { return nil }
            return first
        }
        return nil
    }

    /// 九宫格收藏里有几张图（列表右边写「N 张图片」）
    private func countImages(_ item: [String: Any]) -> Int {
        let content = (item["content"] as? String) ?? ""
        guard let d = content.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let paths = o["paths"] as? [String] else { return 0 }
        return paths.count
    }

    private func load() async {
        items = await API.shared.favorites()
        loading = false
    }

    /// 拍照 / 相册选来的图：传上去，然后存成一条「图片」收藏（微信收藏也能收图片）
    private func saveImage(_ img: UIImage) {
        savingImage = true
        Task {
            do {
                let url = try await API.shared.upload(image: img)
                let ok = await API.shared.addFavorite(kind: "image", content: url,
                                                      title: Tr("图片"), from: "")
                await MainActor.run { app.show(ok ? Tr("已收藏这张图片") : Tr("收藏失败")) }
                if ok { await load() }
            } catch {
                await MainActor.run { app.show((error as? APIError)?.errorDescription ?? "上传失败") }
            }
            savingImage = false
        }
    }

    /// 列表那条预览：笔记里插的 [图] 换成「［图片］」字样（不然一串路径很难看）
    private func previewText(_ s: String) -> String {
        var out: [String] = []
        for line in s.components(separatedBy: "\n") {
            if line.hasPrefix("[图]") { out.append(Tr("［图片］")); continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/* ============================================================ 表情 */

/* ============================================================
   表情（我 → 表情）—— 按微信那一页做：
   · 我的表情：我添加的表情包（点进去看这一包、可以移除）+ 我添加的单个表情（长按删除）
   · 表情商店：后台配的表情包，点「添加」进我的表情，点「移除」拿掉
   · 最近使用：用过的表情排在前面（表情面板也是先给最近用的）
   ============================================================ */
struct StickerViewOld: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var shop: [StickerPack] = []
    @State private var mine = StickerMine()
    /// 我添加过的内置表情包 id（本地那份，点「添加 / 移除」直接改它）
    @State private var installedIds: [String] = StickerLib.ids
    @State private var openPackId: String?
    @State private var confirmRemove: String?
    @State private var addingPhoto = false
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("表情"), back: { dismiss() })

            ScrollView {
                VStack(spacing: 0) {
                    /* ---------- 我的表情 ---------- */
                    sectionTitle(Tr("我的表情"))

                    if !mine.recentList.isEmpty {
                        packRow(icon: "🕘", name: Tr("最近使用"), count: mine.recentList.count)
                            .opacity(0.9)
                        HairLine(inset: 56)
                    }

                    if mine.packList.isEmpty && mine.singleList.isEmpty {
                        Text(Tr("还没有添加表情，去下面的「表情商店」加几个"))
                            .font(pf(13.5))
                            .foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 18)
                            .background(C.cardBg)
                    }

                    ForEach(mine.packList, id: \.self) { p in
                        Button { openPackId = p.id } label: {
                            packRow(icon: p.icon ?? "😀", name: p.name ?? "表情包",
                                    count: (p.stickers ?? []).count)
                        }
                        .buttonStyle(.plain)
                        HairLine(inset: 56)
                    }

                    /* 我添加的内置表情包（本地那份） */
                    ForEach(mineBuiltin, id: \.id) { p in
                        builtinRow(p, added: true)
                        HairLine(inset: 56)
                    }

                    /* 我添加的单个表情 */
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(Tr("添加的单个表情"))
                                .font(pf(15)).foregroundColor(C.label)
                            Spacer()
                            Button { addingPhoto = true } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                    Text(Tr("添加"))
                                }
                                .font(pf(14)).foregroundColor(C.green)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 44)

                        if !mine.singleList.isEmpty {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                                ForEach(mine.singleList, id: \.self) { s in
                                    Button { confirmRemove = s } label: {
                                        Group {
                                            if s.hasPrefix("http") || s.hasPrefix("/uploads") {
                                                RemoteImage(path: s, maxSide: 400)
                                            } else {
                                                Text(s).font(pf(28))
                                            }
                                        }
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 62)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(C.searchBg))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)
                        }
                    }
                    .background(C.cardBg)

                    Spacer().frame(height: 14)

                    /* ---------- 表情商店 ---------- */
                    sectionTitle(Tr("表情商店"))
                    ForEach(shop, id: \.self) { p in
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Text(p.icon ?? "😀").font(pf(26))
                                    .frame(width: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name ?? "表情包").font(pf(16)).foregroundColor(C.label)
                                    Text("\( (p.stickers ?? []).count ) 个表情")
                                        .font(pf(12.5)).foregroundColor(C.subLabel)
                                }
                                Spacer(minLength: 8)
                                if isAdded(p) {
                                    Button { removePack(p) } label: {
                                        Text(Tr("移除"))
                                            .font(pf(14)).foregroundColor(C.subLabel)
                                            .padding(.horizontal, 12).frame(height: 28)
                                            .background(RoundedRectangle(cornerRadius: 5).fill(C.searchBg))
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Button { addPack(p) } label: {
                                        Text(Tr("添加"))
                                            .font(pf(14, .medium)).foregroundColor(.white)
                                            .padding(.horizontal, 12).frame(height: 28)
                                            .background(RoundedRectangle(cornerRadius: 5).fill(C.green))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 62)
                            HairLine(inset: 56)
                        }
                        .background(C.cardBg)
                    }

                    /* 内置表情包（一包一包摆在这儿，点「添加」进我的表情） */
                    ForEach(shopBuiltin, id: \.id) { p in
                        builtinRow(p, added: false)
                    }

                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .sheet(isPresented: Binding(get: { openPackId != nil },
                                    set: { if !$0 { openPackId = nil } })) {
            if let p = (mine.packList + shop).first(where: { $0.id == openPackId }) {
                packDetail(p)
            }
        }
        .sheet(isPresented: $addingPhoto) {
            PhotoPicker { image in addSingle(image) }
        }
        .confirmationDialog(Tr("删除这个表情？"), isPresented: Binding(
            get: { confirmRemove != nil },
            set: { if !$0 { confirmRemove = nil } }
        ), titleVisibility: .visible) {
            Button(Tr("删除"), role: .destructive) {
                if let s = confirmRemove { removeSingle(s) }
                confirmRemove = nil
            }
            Button(Tr("取消"), role: .cancel) { confirmRemove = nil }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        HStack {
            Text(t).font(pf(13)).foregroundColor(C.subLabel)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(C.pageBg)
    }

    /// 我添加过的内置表情包（按添加顺序）
    private var mineBuiltin: [BuiltinPack] {
        installedIds.compactMap { id in BuiltinPacks.all.first(where: { $0.id == id }) }
    }
    /// 还没添加的内置表情包
    private var shopBuiltin: [BuiltinPack] {
        BuiltinPacks.all.filter { !installedIds.contains($0.id) }
    }

    /// 内置表情包在「商店 / 我的表情」里的一行（右边是添加 / 移除）
    private func builtinRow(_ p: BuiltinPack, added: Bool) -> some View {
        HStack(spacing: 12) {
            Text(p.icon).font(pf(26)).frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(pf(16)).foregroundColor(C.label)
                Text("\(p.stickers.count) 个表情")
                    .font(pf(12.5)).foregroundColor(C.subLabel)
            }
            Spacer(minLength: 8)
            Button {
                if added { StickerLib.remove(p.id) } else { StickerLib.add(p.id) }
                installedIds = StickerLib.ids
            } label: {
                Text(added ? Tr("移除") : Tr("添加"))
                    .font(pf(14, added ? .regular : .medium))
                    .foregroundColor(added ? C.subLabel : .white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 5).fill(added ? C.searchBg : C.green))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .background(C.cardBg)
    }

    private func packRow(icon: String, name: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Text(icon).font(pf(24)).frame(width: 40)
            Text(name).font(pf(16)).foregroundColor(C.label)
            Spacer(minLength: 8)
            Text("\(count) 个").font(pf(13)).foregroundColor(C.subLabel)
            Chevron(size: 9, line: 1.6)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(C.cardBg)
        .contentShape(Rectangle())
    }

    /// 一个表情包的详情：看这一包有哪些表情，可以「移除」
    private func packDetail(_ p: StickerPack) -> some View {
        VStack(spacing: 0) {
            NavBar(title: p.name ?? "表情包", back: { openPackId = nil })
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach((p.stickers ?? []).indices, id: \.self) { i in
                        let s = (p.stickers ?? [])[i]
                        Group {
                            if s.hasPrefix("http") || s.hasPrefix("/uploads") {
                                RemoteImage(path: s, maxSide: 400)
                            } else {
                                Text(s).font(pf(34))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 72)
                        .background { CardGlassBox(radius: 8) }
                    }
                }
                .padding(16)
            }
            Button {
                removePack(p)
                openPackId = nil
            } label: {
                Text(Tr("移除这个表情包"))
                    .font(pf(16)).foregroundColor(C.red)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(C.cardBg)
            }
            .buttonStyle(.plain)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
    }

    /* ---------------------------------------------------------- 干活 */

    private func load() async {
        if let r = try? await API.shared.stickerShop() {
            shop = r.shop
            mine = r.mine
        }
        loading = false
    }

    private func isAdded(_ p: StickerPack) -> Bool {
        guard let id = p.id else { return false }
        return mine.packList.contains { $0.id == id }
    }

    private func addPack(_ p: StickerPack) {
        guard let id = p.id else { return }
        Task {
            await API.shared.addStickerPack(id)
            await load()
            app.show(Tr("已添加"))
        }
    }

    private func removePack(_ p: StickerPack) {
        guard let id = p.id else { return }
        Task {
            await API.shared.removeStickerPack(id)
            await load()
            app.show(Tr("已移除"))
        }
    }

    private func addSingle(_ image: UIImage) {
        Task {
            guard let url = try? await API.shared.upload(image: image) else { return }
            await API.shared.addSingleSticker(url)
            await load()
            app.show(Tr("已添加到我的表情"))
        }
    }

    private func removeSingle(_ s: String) {
        Task {
            await API.shared.removeSingleSticker(s)
            await load()
            app.show(Tr("已删除"))
        }
    }
}

/* ============================================================
   状态（我 → ＋状态）——照微信那套：
     · 上面一条输入区：左边是挑中的状态图标，右边「说点什么」写一句（最多 30 字）
     · 下面按后台配的分类，一组一张卡，一格一个状态
     · 右上角「就这样」保存；已经设了状态的，底部可以「结束状态」
   状态 24 小时后自己消失（服务端算的），点自己那一条能看到「谁看过我」。
   ============================================================ */

struct StatusView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var cats: [StatusCategory] = []
    @State private var picked: StatusItem? = nil
    @State private var pickedColor = ""
    @State private var caption = ""
    @State private var saving = false
    @FocusState private var typing: Bool
    /// 我的状态详情（还剩几小时 + 谁看过）
    @State private var myStatus: MyStatus? = nil

    /// 现在有没有状态（有的话底部给「结束状态」）
    private var hasMood: Bool {
        !((app.me?.moodText ?? "").isEmpty && (app.me?.moodIcon ?? "").isEmpty)
    }

    private let cols = [GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("状态"), back: { dismiss() }) {
                Button { save() } label: {
                    Text(Tr("就这样"))
                        .font(pf(15, .medium))
                        .foregroundColor(picked == nil ? C.subLabel : C.green)
                        .padding(.horizontal, 16)
                        .frame(height: L.navH)
                }
                .buttonStyle(.plain)
                .disabled(picked == nil || saving)
            }

            ScrollView {
                VStack(spacing: 10) {
                    composeRow
                    if hasMood, let ms = myStatus { myStatusCard(ms) }
                    ForEach(cats.indices, id: \.self) { i in
                        section(cats[i])
                    }
                    if hasMood { endRow }
                    Spacer().frame(height: 30)
                }
                .padding(.top, 10)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task {
            await load()
            myStatus = try? await API.shared.myStatus()
        }
    }

    /* ---------------------------------------------------------- 上面那条输入区 */

    /// 已经设了状态时显示：还剩几小时 + 谁看过我
    private func myStatusCard(_ ms: MyStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(ms.moodIcon ?? "").font(pf(18))
                Text(ms.moodText ?? "").font(pf(15, .medium)).foregroundColor(C.label)
                Spacer(minLength: 6)
                if let h = ms.hoursLeft {
                    Text(h <= 0 ? Tr("马上过期") : (Tr("还剩 ") + "\(h)" + Tr(" 小时")))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                }
            }
            if let views = ms.views, !views.isEmpty {
                Text(Tr("谁看过我的状态") + "（\(views.count)）")
                    .font(pf(12.5)).foregroundColor(C.subLabel)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(views, id: \.self) { v in
                            VStack(spacing: 4) {
                                Avatar(path: v.avatar ?? "", size: 36, radius: 18)
                                Text(v.name ?? "").font(pf(11)).foregroundColor(C.subLabel).lineLimit(1)
                            }
                            .frame(width: 46)
                        }
                    }
                }
            } else {
                Text(Tr("还没有人看过")).font(pf(12.5)).foregroundColor(C.subLabel)
            }
        }
        .padding(14)
        /* 这张卡也带上状态自己的颜色：淡淡的同色底 + 左侧一道色条，
           比纯白卡更像「我的状态」该有的样子 */
        .background(
            ZStack {
                C.cardBg
                if !statusTint.isEmpty {
                    Color(hexString: statusTint).opacity(0.10)
                }
            }
        )
        .overlay(alignment: .leading) {
            if !statusTint.isEmpty {
                Capsule().fill(Color(hexString: statusTint)).frame(width: 3).padding(.vertical, 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
        .padding(.horizontal, 12)
    }

    /// 我的状态色（没设就空）
    private var statusTint: String {
        let c = MoodColor.clean(app.me?.moodColor)
        if !c.isEmpty { return c }
        return MoodColor.clean(myStatus?.moodColor)
    }

    private var composeRow: some View {
        HStack(spacing: 10) {
            moodBox
            TextField("", text: $caption, prompt: Text(Tr("说点什么…")).foregroundColor(C.subLabel))
                .font(pf(14.5))
                .foregroundColor(C.label)
                .focused($typing)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(Capsule().fill(C.fieldBg))
                .onChange(of: caption) { v in
                    if v.count > 30 { caption = String(v.prefix(30)) }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        /* 整条做成一张卡片：比散着摆更整齐（高级感来自留白和成组） */
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
        .padding(.horizontal, 12)
    }

    private var moodBox: some View {
        let icon = picked?.icon ?? ""
        let on = picked != nil
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? AnyShapeStyle(tileGradient(picked?.color ?? pickedColor))
                         : AnyShapeStyle(C.cardBg))
                .frame(width: 44, height: 44)
            if on {
                Text(icon.isEmpty ? "🙂" : icon).font(pf(22))
            } else {
                Text("＋").font(pf(20)).foregroundColor(C.subLabel)
            }
        }
    }

    /* ---------------------------------------------------------- 一组状态 */

    private func section(_ c: StatusCategory) -> some View {
        let title = c.name ?? ""
        let items = c.items ?? []
        let catColor = MoodColor.clean(c.color)
        return VStack(alignment: .leading, spacing: 12) {
            /* 标题前面加一个小色点：一眼看出这一组是什么色系（高级感主要来自这种细节） */
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hexString: catColor.isEmpty ? "#8A8F99" : catColor))
                    .frame(width: 6, height: 6)
                Text(Tr(title))
                    .font(pf(13, .medium))
                    .foregroundColor(C.subLabel)
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(items, id: \.self) { it in
                    tile(it, fallback: catColor)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func tile(_ it: StatusItem, fallback: String) -> some View {
        let own = MoodColor.clean(it.color)
        let base = own.isEmpty ? (fallback.isEmpty ? "#6F8A38" : fallback) : own
        let on = (picked?.id ?? "-") == (it.id ?? "?")
        return Button { pick(it, base: base) } label: {
            VStack(spacing: 7) {
                /* 图标放一个半透明白圆里，比直接摆在渐变上有质感 */
                ZStack {
                    Circle().fill(Color.white.opacity(0.22)).frame(width: 34, height: 34)
                    Text(it.icon ?? "🙂").font(pf(19))
                }
                Text(Tr(it.label ?? "状态"))
                    .font(pf(12.5, .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 86)
            .background(tileGradient(base))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            /* 选中：白描边 + 右上角一个小勾，比单纯加粗描边更像成品 */
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white, lineWidth: on ? 2 : 0))
            .overlay(alignment: .topTrailing) {
                if on {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.black.opacity(0.18)).frame(width: 15, height: 15))
                        .padding(6)
                }
            }
            .shadow(color: Color.black.opacity(0.10), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }

    /// 格子的底色：主色 + 自动调亮的第二个色做渐变
    private func tileGradient(_ raw: String) -> LinearGradient {
        let c1 = MoodColor.clean(raw)
        let base = c1.isEmpty ? "#6F8A38" : c1
        let c2 = MoodColor.shift(base, to: true)
        let c3 = MoodColor.shift(base, to: false)
        /* 三格渐变（深 → 本色 → 亮）：比两格更有体积感 */
        return LinearGradient(colors: [Color(hexString: c3.isEmpty ? base : c3),
                                       Color(hexString: base),
                                       Color(hexString: c2.isEmpty ? base : c2)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var endRow: some View {
        Button { endMood() } label: {
            Text(Tr("结束状态"))
                .font(pf(15.5))
                .foregroundColor(C.red)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(C.cardBg)
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
    }

    /* ---------------------------------------------------------- 动作 */

    private func load() async {
        cats = (try? await API.shared.statusCategories()) ?? []
        if hasMood {
            pickedColor = MoodColor.clean(app.me?.moodColor)
            caption = app.me?.moodCaption ?? ""
        }
    }

    /// 挑一个：微信挑完就把光标放到「说点什么」，不想写就直接点「就这样」
    private func pick(_ it: StatusItem, base: String) {
        picked = it
        pickedColor = base
        typing = true
    }

    private func save() {
        guard let it = picked, !saving else { return }
        saving = true
        Task {
            await API.shared.setMood(it, caption: caption, fallbackColor: pickedColor)
            app.me = try? await API.shared.me()
            app.show(Tr("状态更新了"))
            saving = false
            dismiss()
        }
    }

    private func endMood() {
        Task {
            await API.shared.setMood(nil)
            app.me = try? await API.shared.me()
            app.show(Tr("状态已取消"))
            dismiss()
        }
    }
}

/* ============================================================
   我的状态详情（微信里点自己那条状态进来的）
   大卡片（图标 + 状态名 + 说点什么 + 还剩 X 小时）+「谁看过我」+ 结束状态
   ============================================================ */

struct StatusDetailView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var info: MyStatus? = nil
    @State private var editing = false

    private var icon: String { info?.moodIcon ?? app.me?.moodIcon ?? "" }
    private var label: String { info?.moodLabel ?? app.me?.moodLabel ?? app.me?.moodText ?? "" }
    private var note: String { info?.moodCaption ?? app.me?.moodCaption ?? "" }
    private var c1: String {
        let mine = MoodColor.clean(info?.moodColor)
        return mine.isEmpty ? MoodColor.clean(app.me?.moodColor) : mine
    }
    private var c2: String {
        let mine = MoodColor.clean(info?.moodColor2)
        return mine.isEmpty ? MoodColor.clean(app.me?.moodColor2) : mine
    }
    private var viewers: [StatusViewer] { info?.views ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("我的状态"), back: { dismiss() }) {
                Button { editing = true } label: {
                    Text(Tr("更改状态"))
                        .font(pf(15))
                        .foregroundColor(C.green)
                        .padding(.horizontal, 16)
                        .frame(height: L.navH)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(spacing: 12) {
                    bigCard
                    viewersCard
                    Spacer().frame(height: 20)
                }
                .padding(.top, 12)
            }
            .background(C.pageBg)

            endButton
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(isPresented: $editing) { StatusView() }
        .task { await reload() }
        .onChange(of: editing) { on in
            if !on { Task { await reload() } }
        }
    }

    private var bigCard: some View {
        let base = c1.isEmpty ? "#5B7F42" : c1
        let second = c2.isEmpty ? MoodColor.shift(base, to: true) : c2
        return VStack(spacing: 10) {
            Text(icon.isEmpty ? "🙂" : icon).font(pf(44))
            if !label.isEmpty {
                Text(Tr(label)).font(pf(17, .medium)).foregroundColor(.white).lineLimit(1)
            }
            if !note.isEmpty {
                Text(note).font(pf(13.5)).foregroundColor(.white.opacity(0.92))
                    .multilineTextAlignment(.center).lineLimit(3)
            }
            Text(leftText).font(pf(11.5)).foregroundColor(.white.opacity(0.82))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 18)
        .background(LinearGradient(colors: [Color(hexString: base),
                                            Color(hexString: second.isEmpty ? base : second)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
    }

    private var leftText: String {
        let h = info?.hoursLeft ?? 0
        if h <= 0 { return Tr("24 小时后自动结束（不到 1 小时）") }
        return "24 小时后自动结束 · 还剩 \(h) 小时"
    }

    private var viewersCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(Tr("谁看过我"))
                    .font(pf(14, .medium))
                    .foregroundColor(C.label)
                Spacer(minLength: 0)
                Text("\(info?.viewerCount ?? viewers.count) 人")
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
            }
            .padding(.horizontal, 15)
            .frame(height: 46)
            HairLine(inset: 15)
            if viewers.isEmpty {
                Text(Tr("还没有人看过你的状态"))
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 18)
            } else {
                ForEach(viewers, id: \.self) { v in
                    viewerRow(v)
                }
            }
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func viewerRow(_ v: StatusViewer) -> some View {
        HStack(spacing: 10) {
            Avatar(path: v.avatar ?? "", size: 34, radius: 17, circle: true)
            Text(v.name ?? "好友")
                .font(pf(15))
                .foregroundColor(C.label)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(TimeFmt.list(v.at))
                .font(pf(12))
                .foregroundColor(C.subLabel)
                .fixedSize()
        }
        .padding(.horizontal, 15)
        .frame(height: 54)
    }

    private var endButton: some View {
        Button { endIt() } label: {
            Text(Tr("结束状态"))
                .font(pf(15.5))
                .foregroundColor(C.red)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(C.cardBg)
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, max(10, L.safeBottom))
    }

    private func reload() async {
        info = try? await API.shared.myStatus()
        app.me = try? await API.shared.me()
    }

    private func endIt() {
        Task {
            await API.shared.endMyStatus()
            app.me = try? await API.shared.me()
            app.show(Tr("状态已取消"))
            dismiss()
        }
    }
}

/* ============================================================
   好友的状态（名片页 / 聊天气泡那一条点进来的）
   好友那边只看得到「图标 + 状态名 + 说点什么 + 还剩几个小时」
   ============================================================ */

struct FriendStatusView: View {
    @Environment(\.dismiss) private var dismiss
    let user: User

    private var base: String {
        let c = MoodColor.clean(user.moodColor)
        return c.isEmpty ? "#5B7F42" : c
    }
    private var second: String {
        let c = MoodColor.clean(user.moodColor2)
        return c.isEmpty ? MoodColor.shift(base, to: true) : c
    }
    private var label: String {
        let l = (user.moodLabel ?? "").trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? (user.moodText ?? "") : l
    }
    private var note: String { user.moodCaption ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("状态"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 10) {
                        Text(user.moodIcon ?? "🙂").font(pf(46))
                        if !label.isEmpty {
                            Text(Tr(label)).font(pf(17, .medium)).foregroundColor(.white)
                        }
                        if !note.isEmpty {
                            Text(note).font(pf(13.5)).foregroundColor(.white.opacity(0.92))
                                .multilineTextAlignment(.center)
                        }
                        Text(leftText).font(pf(11.5)).foregroundColor(.white.opacity(0.82))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .padding(.horizontal, 18)
                    .background(LinearGradient(colors: [Color(hexString: base),
                                                        Color(hexString: second.isEmpty ? base : second)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 12)
                    Spacer().frame(height: 20)
                }
                .padding(.top, 12)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }

    private var leftText: String {
        let exp = Double(user.moodExpiresAt ?? 0)
        guard exp > 0 else { return Tr("24 小时内有效") }
        let left = (exp - Date().timeIntervalSince1970 * 1000) / 3600000
        if left <= 0 { return Tr("已经结束了") }
        if left < 1 { return Tr("24 小时内有效（不到 1 小时）") }
        return "24 小时内有效 · 还剩 \(Int(left.rounded())) 小时"
    }
}

/* ============================================================ 卡包 / 作品 */

/* ============================================================
   朋友们现在的状态（「我」页那颗状态胶囊**旁边**的按钮进来的）
   微信那一栏就是这个：所有好友当前挂着的状态，头像 + 名字 + 状态，
   点一条就进那个人的状态页。
   ============================================================ */

struct FriendsStatusView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    /// 点开某一个好友的状态页
    @State private var picked: User? = nil
    /// 正在放「爱心爆开」动画的那一行（点完 0.5 秒清掉）
    @State private var bursting: String = ""
    /// 本地先记一下赞/取消，省得等服务器回来才变
    @State private var localLikes: [String: Int] = [:]
    @State private var localMine: [String: Bool] = [:]
    /// 谁在听什么（用户要求：把"在听"显示在那个人的状态上）
    @State private var listening: [String: FriendNowPlaying] = [:]

    /// 挂着状态的好友（没挂的不列 —— 微信也只列有状态的）
    private var list: [User] {
        app.contacts.filter { u in
            !((u.moodText ?? "").isEmpty && (u.moodIcon ?? "").isEmpty)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            /* 顶栏标题：默认是**一个缺一丢丢的圆环**（用户要的状态图标）。
               ⚠ 位置用 ZStack 居中对齐（以前用 overlay+padding 算，结果跑到状态栏上去了）。
               想换成文字：后台 ui.json 写 friendsStatusTitle = "朋友的状态" 就会显示文字。 */
            ZStack {
                NavBar(title: UIConfig.text("friendsStatusTitle", ""), back: { dismiss() })
                if UIConfig.text("friendsStatusTitle", "").isEmpty {
                    StatusRingIcon()
                        .allowsHitTesting(false)
                }
            }

            if list.isEmpty {
                VStack(spacing: 10) {
                    Text("🙂").font(pf(30))
                    Text(Tr("朋友们现在都没挂状态")).font(pf(15)).foregroundColor(C.label)
                    Text(Tr("等好友在「我 → 状态」里挂一个，这里就会显示"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 70)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        /* 微信那套排版（用户截了图）：先按**哪天挂的**分组（昨天 / 今天），
                           同一天里再按**状态名**合起来，标题就是微信那句
                           「N 个朋友在吸猫」，下面才是那几个人的头像名字。 */
                        ForEach(sections) { sec in
                            dayHeader(sec.day)
                            ForEach(sec.groups) { g in
                                groupHeader(g)
                                ForEach(g.users) { u in
                                    Button { picked = u } label: { row(u) }
                                        .buttonStyle(.plain)
                                    HairLine(inset: 72)
                                }
                            }
                        }
                    }
                    Spacer().frame(height: 30)
                }
                .background(C.pageBg)
            }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(item: $picked) { u in
            NavigationStack { FriendStatusView(user: u).environmentObject(app) }
        }
        .task {
            let list = await API.shared.friendsNowPlaying()
            var m: [String: FriendNowPlaying] = [:]
            for f in list { m[f.id] = f }
            listening = m
        }
    }

    private func row(_ u: User) -> some View {
        return HStack(spacing: 12) {
            Avatar(path: u.avatarPath, size: 40, radius: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(u.name).font(pf(16)).foregroundColor(C.label).lineLimit(1)
                if let f = listening[u.id] {
                    /* 在听什么：排在状态下面一行（微信听一听也是这么显示的） */
                    HStack(spacing: 4) {
                        Image(systemName: "music.note").font(.system(size: 10.5))
                        Text(Tr("在听《") + f.title + "》").lineLimit(1)
                    }
                    .font(pf(12))
                    .foregroundColor(Color(hex: 0x576B95))
                }
                Text(left(u)).font(pf(12)).foregroundColor(C.subLabel).lineLimit(1)
            }
            Spacer(minLength: 6)
            /* 点赞：微信那套「爱心」，点了会爆开一下 */
            Button { like(u) } label: {
                ZStack {
                    Image(systemName: liked(u) ? "heart.fill" : "heart")
                        .font(.system(size: 17))
                        .foregroundColor(liked(u) ? Color(hex: 0xFF5A5A) : C.subLabel)
                    if bursting == u.id { HeartBurst() }
                    if likeCount(u) > 0 {
                        Text("\(likeCount(u))")
                            .font(pf(10))
                            .foregroundColor(C.subLabel)
                            .offset(x: 13, y: 9)
                    }
                }
                .frame(width: 42, height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(u.moodIcon ?? "").font(pf(18))
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .contentShape(Rectangle())
    }

    /* ---------------- 分组（微信那套排版的骨架） ---------------- */

    /* ---------------- 点赞 ---------------- */

    private func liked(_ u: User) -> Bool {
        if let v = localMine[u.id] { return v }
        return (u.moodLikes ?? []).contains(app.me?.id ?? "")
    }

    private func likeCount(_ u: User) -> Int {
        if let n = localLikes[u.id] { return n }
        return u.moodLikeCount ?? (u.moodLikes ?? []).count
    }

    /// 点爱心：本地先翻一下（马上有反应 + 爆开动画），再去服务器落定
    private func like(_ u: User) {
        let now = !liked(u)
        localMine[u.id] = now
        localLikes[u.id] = max(0, likeCount(u) + (now ? 1 : -1))
        if now { bursting = u.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if bursting == u.id { bursting = "" }
        }
        Task {
            if let r = await API.shared.statusLike(u.id) {
                localMine[u.id] = r.liked
                localLikes[u.id] = r.count
            }
            await app.loadContacts()
        }
    }

    private struct StatusGroup: Identifiable {
        var id: String { key }
        var key: String          // 状态名（吸猫 / 搬砖…）
        var icon: String
        var users: [User]
    }

    private struct DaySection: Identifiable {
        var id: String { day }
        var day: String
        var groups: [StatusGroup]
    }

    /// 先按天、再按状态名分组（都按"什么时候挂上去的"排）
    private var sections: [DaySection] {
        var order: [String] = []
        var byDay: [String: [User]] = [:]
        for u in list.sorted(by: { setAt($0) > setAt($1) }) {
            let d = dayOf(setAt(u))
            if byDay[d] == nil { byDay[d] = []; order.append(d) }
            byDay[d]?.append(u)
        }
        return order.map { d in
            let users = byDay[d] ?? []
            var gOrder: [String] = []
            var byKey: [String: StatusGroup] = [:]
            for u in users {
                let label = ((u.moodLabel ?? "").isEmpty ? (u.moodText ?? "") : (u.moodLabel ?? ""))
                let key = label.isEmpty ? Tr("状态") : label
                if byKey[key] == nil {
                    byKey[key] = StatusGroup(key: key, icon: u.moodIcon ?? "", users: [])
                    gOrder.append(key)
                }
                byKey[key]?.users.append(u)
            }
            return DaySection(day: d, groups: gOrder.compactMap { byKey[$0] })
        }
    }

    /// 状态是**什么时候挂上的**：过期时间往回推 24 小时（服务器就是这么算的）
    private func setAt(_ u: User) -> Double {
        let exp = Double(u.moodExpiresAt ?? 0)
        return exp > 0 ? (exp - 24 * 3600 * 1000) : 0
    }

    private func dayOf(_ ms: Double) -> String {
        guard ms > 0 else { return Tr("更早") }
        let d = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return Tr("今天") }
        if cal.isDateInYesterday(d) { return Tr("昨天") }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d),
                                      to: cal.startOfDay(for: Date())).day ?? 99
        if days == 2 { return Tr("前天") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return f.string(from: d)
    }

    private func dayHeader(_ t: String) -> some View {
        HStack {
            Text(t).font(pf(13)).foregroundColor(C.subLabel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    /// 微信那句「1 个朋友在吸猫」
    private func groupHeader(_ g: StatusGroup) -> some View {
        HStack(spacing: 5) {
            if !g.icon.isEmpty { Text(g.icon).font(pf(14)) }
            Text("\(g.users.count) " + Tr("个朋友在") + g.key)
                .font(pf(14))
                .foregroundColor(Color(hex: 0x576B95))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private func left(_ u: User) -> String {
        let exp = Double(u.moodExpiresAt ?? 0)
        guard exp > 0 else { return "" }
        let h = (exp - Date().timeIntervalSince1970 * 1000) / 3600000
        if h <= 0 { return "" }
        if h < 1 { return Tr("还剩不到 1 小时") }
        return Tr("还剩 ") + String(Int(h.rounded())) + Tr(" 小时")
    }
}

/* ============================================================
   状态那个图标：一个**缺一丢丢的圆环**（用户说"字改成一个圆缺一丢丢"）
   ============================================================ */

struct StatusRingIcon: View {
    var size: CGFloat = 26
    var color: Color = C.label

    var body: some View {
        Circle()
            .trim(from: 0.04, to: 0.96)          // 缺一丢丢
            .stroke(color, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .frame(width: size, height: size)
    }
}

/// 「爱心爆开」：一颗心放大淡出 + 一圈小点飞出去（点完 0.45 秒结束）
struct HeartBurst: View {
    @State private var t: CGFloat = 0

    var body: some View {
        ZStack {
            Image(systemName: "heart.fill")
                .font(.system(size: 20))
                .foregroundColor(Color(hex: 0xFF5A5A))
                .scaleEffect(1 + t * 1.5)
                .opacity(Double(1 - t))
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) / 8 * 2 * Double.pi
                Circle()
                    .fill(Color(hex: 0xFF7A7A))
                    .frame(width: 4, height: 4)
                    .offset(x: CGFloat(cos(a)) * (8 + t * 26),
                            y: CGFloat(sin(a)) * (8 + t * 26))
                    .opacity(Double(1 - t))
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { t = 1 }
        }
    }
}

struct WalletCardView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("卡包"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    GroupCard {
                        row("零钱", "¥\(moneyFmt(app.me?.balance ?? 0))")
                        HairLine(inset: 16)
                        row("建设银行储蓄卡", "尾号 2125")
                        HairLine(inset: 16)
                        row("单笔转账限额", "¥20000")
                    }
                    .padding(.top, 8)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(pf(17)).foregroundColor(C.label)
            Spacer()
            Text(value).font(pf(15)).foregroundColor(C.subLabel)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }
}

struct WorksView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var works: [FeedItem] = []
    @State private var playing: FeedItem?
    @State private var loading = true
    /// 三列方块网格（抖音个人主页那样）
    private let cols = [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("作品"), back: { dismiss() })
            if loading && works.isEmpty {
                Spacer(); ProgressView(); Spacer()
            } else if works.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "rectangle.stack").font(pf(34)).foregroundColor(C.subLabel)
                    Text(Tr("还没有作品")).font(pf(15)).foregroundColor(C.subLabel)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 3) {
                        ForEach(works) { w in
                            Button { playing = w } label: { tile(w) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 20)
                }
                .background(C.pageBg)
            }
        }
        .background(C.pageBg.ignoresSafeArea(edges: .bottom))
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(item: $playing) { w in
            FeedPlayerSheet(item: w, all: works)
        }
        .task {
            /* 「作品」这一页只放我自己发布的（别人的作品在视频号里刷） */
            let mine = (try? await API.shared.myFeedItems()) ?? []
            works = mine.isEmpty ? ((try? await API.shared.feedItems()) ?? []).filter { $0.mine == true } : mine
            loading = false
        }
    }

    /// 一个方块：有封面就显示封面，没有就用深色底 + 播放图标 + 点赞数
    private func tile(_ w: FeedItem) -> some View {
        ZStack {
            if !(w.cover ?? "").isEmpty {
                RemoteImage(path: w.cover ?? "")
            } else {
                LinearGradient(colors: [Color(hex: 0x2A2A2E), Color(hex: 0x141416)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if (w.cover ?? "").isEmpty {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.85))
            }
            VStack {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 10))
                    Text("\(w.likes ?? 0)").font(pf(11.5, .medium))
                    Spacer(minLength: 0)
                    if w.mine == true {
                        Text(Tr("我的")).font(pf(10.5)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(C.green))
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .contentShape(Rectangle())
    }
}
