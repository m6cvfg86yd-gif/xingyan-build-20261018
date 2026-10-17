import SwiftUI

/* ============================================================
   表情商店（高级版）

   照微信那套逻辑，样子换成「商店」该有的样子：
     · 顶上深色英雄卡：标题 + 「共 N 个表情包 · M 张表情」+ 卡里嵌一条搜索框
     · 我的表情：已经添加的包横着滑（大图标卡片），点开看整包、能移除
     · 我添加的单个表情：从相册加一张进来
     · 表情商店：分类胶囊 + 两列「卡片宫格」，每张卡是封面 + 名字 + 数量，
       右上角一个圆形「＋ / ✓」，点卡片看整包预览
   添加 / 移除之后，聊天表情面板底下那排立刻跟着变。
   ============================================================ */

struct StickerStore: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var catalog = StickerCatalog.shared

    /// 商店里的一包（内置的 / 图库的 / 服务端下发的，统一成一种）
    struct ShopPack: Identifiable {
        let id: String
        let name: String
        let icon: String
        let count: Int
        let isImage: Bool
        let category: String
        let stickers: [String]
    }

    @State private var serverShop: [StickerPack] = []
    @State private var mineServer = StickerMine()
    @State private var builtinIds: [String] = StickerLib.ids
    @State private var remoteIds: [String] = StickerLib.remoteIds
    @State private var category = "all"
    @State private var keyword = ""
    @State private var preview: ShopPack? = nil
    @State private var addingPhoto = false
    @State private var confirmRemove: String? = nil
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("表情"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    heroCard
                    mineBlock
                    singleBlock
                    shopBlock
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 30)
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await load() }
        .sheet(item: $preview) { p in previewSheet(p) }
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

    /* ---------------------------------------------------------- 顶上英雄卡 */

    private var heroCard: some View {
        PanelHeroCard(glow: C.green) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 54, height: 54)
                    Group {
                        if let first = installedPacks.first {
                            if first.isImage {
                                StickerThumb(url: first.icon)
                            } else {
                                Text(first.icon).font(pf(28))
                            }
                        } else {
                            Text("🧩").font(pf(28))
                        }
                    }
                    .frame(width: 42, height: 42)
                }
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 0.8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(Tr("表情商店"))
                        .font(pf(18, .semibold))
                        .foregroundColor(.white)
                    Text(Tr("共 ") + "\(allPacks.count)" + Tr(" 个表情包 · ") + "\(totalStickers)" + Tr(" 张表情"))
                        .font(pf(12))
                        .foregroundColor(.white.opacity(0.62))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(installedPacks.count)")
                        .font(pf(22, .semibold))
                        .foregroundColor(.white)
                    Text(Tr("已添加"))
                        .font(pf(11))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            /* 搜索框就嵌在英雄卡里 */
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
                ZStack(alignment: .leading) {
                    if keyword.isEmpty {
                        Text(Tr("搜索表情包"))
                            .font(pf(15))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    TextField("", text: $keyword)
                        .font(pf(15))
                        .foregroundColor(.white)
                        .tint(.white)
                }
                if !keyword.isEmpty {
                    Button { keyword = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.8))
        }
    }

    private var totalStickers: Int {
        allPacks.reduce(0) { $0 + $1.count }
    }

    /* ---------------------------------------------------------- 我的表情 */

    private var mineBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(Tr("我的表情"), sub: "\(installedPacks.count) " + Tr("个包"))
            if installedPacks.isEmpty {
                PanelCard {
                    HStack(spacing: 10) {
                        PanelIcon(symbol: "sparkles", colors: PanelTint.purple, size: 28)
                        Text(Tr("还没有添加表情包，去下面「表情商店」点右上角的 ＋"))
                            .font(pf(13))
                            .foregroundColor(C.subLabel)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(installedPacks) { p in
                            Button { preview = p } label: { mineCard(p) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func mineCard(_ p: ShopPack) -> some View {
        VStack(spacing: 6) {
            Group {
                if p.isImage {
                    StickerThumb(url: p.icon)
                } else {
                    Text(p.icon).font(pf(30))
                }
            }
            .frame(width: 62, height: 62)
            .background { CardGlassBox(radius: 15) }
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(C.hairline, lineWidth: 0.6))
            .shadow(color: Color.black.opacity(0.05), radius: 6, y: 2)

            Text(p.name)
                .font(pf(11.5))
                .foregroundColor(C.label)
                .lineLimit(1)
                .frame(width: 66)
        }
    }

    /* ---------------------------------------------------------- 单个表情 */

    private var singleBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(Tr("我添加的单个表情"))
                    .font(pf(12.5, .medium))
                    .foregroundColor(C.subLabel)
                Spacer(minLength: 0)
                Button { addingPhoto = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text(Tr("从相册添加")).font(pf(12.5))
                    }
                    .foregroundColor(C.green)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 6)

            PanelCard {
                if mineServer.singleList.isEmpty {
                    Text(Tr("还没有加过单个表情"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        ForEach(mineServer.singleList, id: \.self) { s in
                            Button { confirmRemove = s } label: {
                                Group {
                                    if s.hasPrefix("http") || s.hasPrefix("/uploads") || s.hasPrefix("/emoji") {
                                        StickerThumb(url: s)
                                    } else {
                                        Text(s).font(pf(26))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.pageBg))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    /* ---------------------------------------------------------- 表情商店 */

    private var shopBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(Tr("表情商店"),
                          sub: loading ? Tr("加载中…") : "\(storePacks.count) " + Tr("个包"))
            categoryChips
                .padding(.bottom, 10)
            if storePacks.isEmpty {
                PanelCard {
                    Text(loading ? Tr("正在拉表情包…") : Tr("这个分类里没有可添加的包了"))
                        .font(pf(13.5))
                        .foregroundColor(C.subLabel)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                          spacing: 10) {
                    ForEach(storePacks) { p in
                        Button { preview = p } label: { shopCard(p) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 一张包卡片：封面（按分类配色）+ 右上角圆形「＋」+ 名字 / 数量
    private func shopCard(_ p: ShopPack) -> some View {
        let added = isInstalled(p.id)
        let tint = Self.tint(for: p.category)
        return VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    LinearGradient(colors: [tint[0].opacity(0.22), tint[1].opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Group {
                        if p.isImage {
                            StickerThumb(url: p.icon)
                        } else {
                            Text(p.icon).font(pf(34))
                        }
                    }
                    .frame(width: 62, height: 62)
                }
                .frame(height: 96)
                .frame(maxWidth: .infinity)

                Button { toggle(p) } label: {
                    Image(systemName: added ? "checkmark" : "plus")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(added ? C.subLabel : C.green))
                        .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.18), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name)
                        .font(pf(14.5, .medium))
                        .foregroundColor(C.label)
                        .lineLimit(1)
                    Text("\(p.count) " + Tr("个表情"))
                        .font(pf(11.5))
                        .foregroundColor(C.subLabel)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.top, 9)
            .padding(.bottom, 11)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background { CardGlassBox(radius: 16) }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(C.hairline, lineWidth: 0.7))
        .shadow(color: Color.black.opacity(0.05), radius: 8, y: 3)
    }

    /// 分类配色（封面那层渐变）
    private static func tint(for category: String) -> [Color] {
        switch category {
        case "builtin": return PanelTint.green
        case "server":  return PanelTint.teal
        case "wx":      return PanelTint.green
        case "ap1":     return PanelTint.orange
        case "ap2":     return PanelTint.teal
        case "ap3":     return PanelTint.blue
        case "ap4":     return PanelTint.purple
        case "ap5":     return PanelTint.blue
        case "ap6":     return PanelTint.orange
        case "ap7":     return PanelTint.gray
        case "ap8":     return PanelTint.red
        case "ap9":     return PanelTint.teal
        default:
            /* 认不出来的分类：按名字挑一个固定的（同一分类永远同一个色） */
            let pick = abs(category.hashValue) % 6
            return [PanelTint.green, PanelTint.blue, PanelTint.purple,
                    PanelTint.orange, PanelTint.teal, PanelTint.gray][pick]
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("all", Tr("全部"))
                chip("builtin", Tr("内置"))
                if !serverShop.isEmpty { chip("server", Tr("线上")) }
                ForEach(catalog.categories) { c in chip(c.id, c.name) }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func chip(_ id: String, _ name: String) -> some View {
        let on = category == id
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { category = id }
        } label: {
            Text(name)
                .font(pf(13.5, on ? .medium : .regular))
                .foregroundColor(on ? .white : C.label)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(
                    Capsule().fill(on
                        ? AnyShapeStyle(LinearGradient(colors: PanelTint.green,
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(C.cardBg))
                )
                .overlay(Capsule().stroke(on ? Color.clear : C.hairline, lineWidth: 0.6))
                .shadow(color: Color.black.opacity(on ? 0.12 : 0.04), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String, sub: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(pf(12.5, .medium)).foregroundColor(C.subLabel)
            Spacer(minLength: 0)
            Text(sub).font(pf(11.5)).foregroundColor(C.subLabel.opacity(0.8))
        }
        .padding(.horizontal, 6)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    /* ---------------------------------------------------------- 整包预览 */

    private func previewSheet(_ p: ShopPack) -> some View {
        let added = isInstalled(p.id)
        let tint = Self.tint(for: p.category)
        return VStack(spacing: 0) {
            NavBar(title: p.name, back: { preview = nil })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    /* 头的封面卡 */
                    HStack(spacing: 12) {
                        ZStack {
                            LinearGradient(colors: [tint[0].opacity(0.25), tint[1].opacity(0.12)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                            Group {
                                if p.isImage { StickerThumb(url: p.icon) } else { Text(p.icon).font(pf(30)) }
                            }
                            .frame(width: 52, height: 52)
                        }
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.name).font(pf(18, .semibold)).foregroundColor(C.label).lineLimit(1)
                            Text("\(p.count) " + Tr("个表情")).font(pf(12.5)).foregroundColor(C.subLabel)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { CardGlassBox(radius: 18) }
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(C.hairline, lineWidth: 0.7))
                    .shadow(color: Color.black.opacity(0.05), radius: 8, y: 3)
                    .padding(.horizontal, 14)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                        ForEach(p.stickers.indices, id: \.self) { i in
                            Group {
                                if p.isImage {
                                    StickerThumb(url: p.stickers[i])
                                } else {
                                    Text(p.stickers[i]).font(pf(30))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 62)
                            .background { CardGlassBox(radius: 12) }
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(C.hairline, lineWidth: 0.6))
                        }
                    }
                    .padding(.horizontal, 14)

                    Button {
                        toggle(p)
                        preview = nil
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: added ? "trash" : "plus")
                                .font(.system(size: 14, weight: .semibold))
                            Text(added ? Tr("移除这个表情包") : Tr("添加到我的表情"))
                                .font(pf(16, .medium))
                        }
                        .foregroundColor(added ? C.red : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(added
                                      ? AnyShapeStyle(C.cardBg)
                                      : AnyShapeStyle(LinearGradient(colors: PanelTint.green,
                                                                     startPoint: .topLeading,
                                                                     endPoint: .bottomTrailing)))
                        )
                        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .stroke(added ? C.red.opacity(0.35) : Color.clear, lineWidth: 1))
                        .shadow(color: Color.black.opacity(added ? 0.03 : 0.14), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        /* 2026-10-16：表情包预览这一层补左滑返回 */
        .swipeBack { preview = nil }
    }

    /* ---------------------------------------------------------- 数据 */

    private var allPacks: [ShopPack] {
        var out: [ShopPack] = []
        for b in BuiltinPacks.all {
            out.append(ShopPack(id: b.id, name: b.name, icon: b.icon, count: b.stickers.count,
                                isImage: false, category: "builtin", stickers: b.stickers))
        }
        for r in catalog.packs {
            out.append(ShopPack(id: r.id, name: r.name, icon: r.icon, count: r.files.count,
                                isImage: true, category: r.category, stickers: r.paths))
        }
        for s in serverShop {
            out.append(ShopPack(id: s.id ?? "", name: s.name ?? "表情包", icon: s.icon ?? "😀",
                                count: (s.stickers ?? []).count, isImage: false, category: "server",
                                stickers: s.stickers ?? []))
        }
        return out
    }

    private var installedPacks: [ShopPack] {
        allPacks.filter { isInstalled($0.id) }
    }

    private var storePacks: [ShopPack] {
        let k = keyword.trimmingCharacters(in: .whitespaces)
        return allPacks.filter { p in
            guard !isInstalled(p.id) else { return false }
            if category != "all" && p.category != category { return false }
            if !k.isEmpty && !p.name.localizedCaseInsensitiveContains(k) { return false }
            return true
        }
    }

    private func isInstalled(_ id: String) -> Bool {
        if BuiltinPacks.all.contains(where: { $0.id == id }) { return builtinIds.contains(id) }
        if catalog.packs.contains(where: { $0.id == id }) { return remoteIds.contains(id) }
        return mineServer.packList.contains { $0.id == id }
    }

    private func toggle(_ p: ShopPack) {
        if BuiltinPacks.all.contains(where: { $0.id == p.id }) {
            if builtinIds.contains(p.id) { StickerLib.remove(p.id) } else { StickerLib.add(p.id) }
            builtinIds = StickerLib.ids
            app.show(builtinIds.contains(p.id) ? Tr("已添加「") + p.name + Tr("」") : Tr("已移除"))
            return
        }
        if catalog.packs.contains(where: { $0.id == p.id }) {
            if remoteIds.contains(p.id) { StickerLib.removeRemote(p.id) } else { StickerLib.addRemote(p.id) }
            remoteIds = StickerLib.remoteIds
            app.show(remoteIds.contains(p.id) ? Tr("已添加「") + p.name + Tr("」") : Tr("已移除"))
            return
        }
        Task {
            if mineServer.packList.contains(where: { $0.id == p.id }) {
                await API.shared.removeStickerPack(p.id)
            } else {
                await API.shared.addStickerPack(p.id)
            }
            await load()
        }
    }

    private func load() async {
        if let r = try? await API.shared.stickerShop() {
            serverShop = r.shop
            mineServer = r.mine
        }
        await StickerCatalog.shared.loadIfNeeded()
        loading = false
    }

    private func addSingle(_ image: UIImage) {
        Task {
            guard let url = try? await API.shared.upload(image: image) else {
                app.show(Tr("上传失败，再试一次"))
                return
            }
            await API.shared.addSingleSticker(url)
            await load()
            app.show(Tr("已加到我的表情"))
        }
    }

    private func removeSingle(_ s: String) {
        Task {
            await API.shared.removeSingleSticker(s)
            await load()
        }
    }
}

/// 老的商店视图留着改名（新商店见 StickerStore），呼叫的地方一个字都不用改
struct StickerView: View {
    var body: some View { StickerStore() }
}
