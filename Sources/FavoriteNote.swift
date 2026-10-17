import SwiftUI

/* ============================================================
   收藏里的「写笔记」（2026-10-12 加）

   收藏页右上角一颗「＋」→ 写一条笔记（纯文字，最多 2 万字）→ 存进收藏。
   存的还是同一条通道：POST /api/favorites（kind = text），所以聊天里收藏的
   文字和手写笔记在同一页混排、同一套搜索/筛选/删除，换设备也跟着账号走。

   点开一条文字收藏 = 笔记详情：全文 + 复制 + 编辑 + 删除。
   编辑走「删掉旧的那条、加一条新的」（服务端只有 POST/DELETE 两个口），
   所以改完会排到最前面。
   ============================================================ */

struct FavoriteNoteComposeSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// 编辑时：被编辑那条的 id（空 = 新建）
    let editingId: String
    /// 编辑时：原来的文字
    let initial: String
    /// 存完喊一声，收藏页重新拉一遍
    let onSaved: () -> Void

    @State private var text = ""
    @State private var busy = false
    @State private var msg = ""
    @FocusState private var focused: Bool
    /// 笔记里插图片（微信笔记也能插）：走相册选一张，传上去，**在编辑区下面把图排出来**
    @State private var showPic = false
    @State private var picBusy = false
    /// 已经插进去的图（存的时候才拼回正文那几行 [图]路径 —— 编辑时不再给用户看"代码"）
    @State private var pics: [String] = []

    init(editingId: String = "", initial: String = "", onSaved: @escaping () -> Void) {
        self.editingId = editingId
        self.initial = initial
        self.onSaved = onSaved
        /* 老笔记里 [图]路径 那几行拆出来当图片，剩下的当正文 ——
           这样编辑一条插过图的笔记，看到的还是图，而不是一串路径 */
        var body: [String] = []
        var imgs: [String] = []
        for line in initial.components(separatedBy: "\n") {
            if line.hasPrefix("[图]") { imgs.append(String(line.dropFirst(3))) }
            else { body.append(line) }
        }
        _text = State(initialValue: body.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines))
        _pics = State(initialValue: imgs)
    }

    /// 有字、或者只插了图没写字，都算一条能存的笔记
    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pics.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: editingId.isEmpty ? Tr("写笔记") : Tr("编辑笔记"), back: { dismiss() }) {
                Button { Task { await save() } } label: {
                    Text(busy ? Tr("保存中…") : Tr("保存"))
                        .font(pf(15, .medium))
                        .foregroundColor(canSave ? C.green : C.subLabel)
                        .padding(.horizontal, 14).frame(height: 32)
                }
                .buttonStyle(.plain)
                .disabled(busy || !canSave)
            }

            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(Tr("写点什么…（最多 2 万字）"))
                            .font(pf(16)).foregroundColor(C.subLabel)
                            .padding(.horizontal, 14).padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(pf(16))
                        .foregroundColor(C.label)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 10).padding(.top, 4)
                        .focused($focused)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                /* 插进来的图片就摆在正文下面（微信笔记也是这样：图是真图，不是一行代码）。
                   每张右上角一个 ✕，点一下就拿掉。 */
                if !pics.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                        ForEach(pics, id: \.self) { p in
                            ZStack(alignment: .topTrailing) {
                                RemoteImage(path: p, mode: .fill, maxSide: 600)
                                    .frame(height: 92)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                Button { pics.removeAll { $0 == p } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 17))
                                        .foregroundColor(.white)
                                        .shadow(color: .black.opacity(0.35), radius: 1.5)
                                        .padding(4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                }
            }
            .background(C.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 12)

            /* 笔记的小工具条（照微信笔记底部那排）：插图片 / 插分割线 */
            HStack(spacing: 10) {
                Button { showPic = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "photo").font(.system(size: 14))
                        Text(Tr("插入图片")).font(pf(13.5))
                    }
                    .foregroundColor(C.green)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Capsule().fill(C.cardBg))
                }
                .buttonStyle(.plain)
                .disabled(picBusy)

                Button {
                    text += "\n————————\n"
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "minus").font(.system(size: 14))
                        Text(Tr("分割线")).font(pf(13.5))
                    }
                    .foregroundColor(C.green)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Capsule().fill(C.cardBg))
                }
                .buttonStyle(.plain)

                if picBusy { ProgressView().scaleEffect(0.7) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.top, 8)

            HStack(spacing: 10) {
                if !msg.isEmpty {
                    Text(msg).font(pf(12.5)).foregroundColor(C.subLabel)
                }
                Spacer(minLength: 0)
                Text(String(text.count) + " / 20000")
                    .font(pf(12)).foregroundColor(C.subLabel)
            }
            .padding(.horizontal, 16).padding(.top, 8)

            Spacer(minLength: 0)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .task { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true } }
        .sheet(isPresented: $showPic) {
            PhotoPicker { img in insertImage(img) }
        }
    }

    /// 选了一张图：传上去，然后加进 `pics`（编辑区下面立刻出现这张图）
    private func insertImage(_ img: UIImage) {
        picBusy = true
        Task {
            do {
                let url = try await API.shared.upload(image: img)
                pics.append(url)
                msg = Tr("图片已插入")
            } catch {
                msg = (error as? APIError)?.errorDescription ?? "图片上传失败"
            }
            picBusy = false
        }
    }

    private func save() async {
        /* 存的时候才把图拼回正文：文字在前，图片按插入顺序跟在后面（每张一行 [图]路径） */
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pics.isEmpty {
            let imgs = pics.map { "[图]" + $0 }.joined(separator: "\n")
            body = body.isEmpty ? imgs : (body + "\n" + imgs)
        }
        guard !body.isEmpty else { return }
        busy = true
        msg = ""
        /* 标题取第一行（前 24 个字）——列表里一眼能看出这条是什么 */
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? body
        let title = String(firstLine.prefix(24))
        /* 编辑走 PATCH（id 和位置都不变）；新建才 POST。
           以前是「删旧加新」，改完会跳到最前面 —— 微信不会。 */
        let ok: Bool
        if editingId.isEmpty {
            ok = await API.shared.addFavorite(kind: "text", content: body, title: title, from: "")
        } else {
            ok = await API.shared.updateFavorite(id: editingId, content: body, title: title)
        }
        busy = false
        if ok {
            DiagLog.shared.note("收藏：保存了一条笔记（" + String(body.count) + " 字）")
            onSaved()
            dismiss()
        } else {
            msg = Tr("保存失败，再试一次")
        }
    }
}

/// 点开一条文字收藏：全文 + 复制 / 编辑 / 删除
struct FavoriteNoteDetailSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let id: String
    let content: String
    /// 这条是不是置顶的（微信收藏能置顶）
    var pinned: Bool = false
    /// 改了 / 删了以后收藏页要重拉
    let onChanged: () -> Void

    @State private var editing = false
    @State private var copied = false
    @State private var isPinned = false
    @State private var showForward = false
    /// 点笔记里的图看大图（用 overlay 弹，不在聊天页那层挂全屏 cover）
    @State private var viewerPath: String?

    /// 这条笔记里插了图没有（转发时决定当「笔记卡片」还是当普通文字发）
    private var hasPic: Bool {
        content.components(separatedBy: "\n").contains { $0.hasPrefix("[图]") }
    }

    /// 笔记正文按行拆（[图]路径 那几行画成图片，其它当文字）
    private var lines: [String] {
        content.components(separatedBy: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("笔记"), back: { dismiss() }) {
                Button {
                    UIPasteboard.general.string = content
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Text(copied ? Tr("已复制") : Tr("复制"))
                        .font(pf(15, .medium)).foregroundColor(C.green)
                        .padding(.horizontal, 14).frame(height: 32)
                }
                .buttonStyle(.plain)
            }

            ScrollView(showsIndicators: false) {
                /* 正文：文字照旧，插进去的图片按原比例画出来（微信笔记就是这样） */
                VStack(alignment: .leading, spacing: 8) {
                    if content.isEmpty {
                        Text(Tr("（空）")).font(pf(16)).foregroundColor(C.subLabel)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            if line.hasPrefix("[图]") {
                                let path = String(line.dropFirst(3))
                                NoteImageBlock(path: path) { p in viewerPath = p }
                            } else if !line.isEmpty {
                                Text(line)
                                    .font(pf(16))
                                    .foregroundColor(C.label)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(14)
                .background(C.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 12)

                VStack(spacing: 0) {
                    /* 置顶（微信收藏也是这一项） */
                    Button { Task { await pin(!isPinned) } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isPinned ? "pin.slash" : "pin").font(.system(size: 15))
                            Text(isPinned ? Tr("取消置顶") : Tr("置顶")).font(pf(16))
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(C.label)
                        .padding(.horizontal, 16).frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    HairLine(inset: 16)
                    /* 转发给朋友（微信收藏点进去第一项就是这个） */
                    Button { showForward = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrowshape.turn.up.right").font(.system(size: 15))
                            Text(Tr("转发给朋友")).font(pf(16))
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(C.label)
                        .padding(.horizontal, 16).frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    HairLine(inset: 16)
                    Button { editing = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.and.pencil").font(.system(size: 15))
                            Text(Tr("编辑这条笔记")).font(pf(16))
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(C.label)
                        .padding(.horizontal, 16).frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    HairLine(inset: 16)
                    Button { Task { await remove() } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "trash").font(.system(size: 15))
                            Text(Tr("删除")).font(pf(16))
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(C.red)
                        .padding(.horizontal, 16).frame(height: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(C.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                Spacer().frame(height: 30)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .overlay {
            if let p = viewerPath, !p.isEmpty {
                PhotoPager(paths: [p], startIndex: 0, showActions: true) { viewerPath = nil }
            }
        }
        .task { isPinned = pinned }
        /* 转发给朋友：走聊天那套「先选人」（ForwardPickerView） */
        .sheet(isPresented: $showForward) {
            /* 笔记里有图 → 发「笔记卡片」（对面点开才看全文、图是真图）；
               纯文字 → 直接当文字发。以前一律按 text 发，插过图的笔记转过去
               对面看到的就是一行行 [图]路径。 */
            ForwardPickerView(items: [ForwardItem(kind: hasPic ? "note" : "text", content: content)]) { }
                .environmentObject(app)
        }
        .sheet(isPresented: $editing) {
            FavoriteNoteComposeSheet(editingId: id, initial: content) {
                onChanged()
                dismiss()
            }
            .environmentObject(app)
        }
    }

    private func pin(_ on: Bool) async {
        if await API.shared.updateFavorite(id: id, pinned: on) {
            isPinned = on
            DiagLog.shared.note(on ? "收藏：置顶了一条" : "收藏：取消置顶")
            onChanged()
        }
    }

    private func remove() async {
        await API.shared.deleteFavorite(id)
        DiagLog.shared.note("收藏：删掉了一条笔记")
        onChanged()
        dismiss()
    }
}
