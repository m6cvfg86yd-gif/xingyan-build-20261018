import SwiftUI

/* ============================================================
   分类页（2026-10-17 用户：「底栏推荐换成分类页，按照大商城质感做」）

   照淘宝/京东那套分类页的骨架：
     · 顶上一条搜索（点了进搜索页）
     · 左栏：分类竖排；**选中那格白底 + 红字 + 左侧一根红条**，一眼知道自己在哪一格
     · 右栏：这个分类的标签格 + 商品双列卡片（卡片就是商城主推那套：渐变底 + 细边 + 柔和投影）
     · 分类来自后台商品里的 cate 字段，后台加商品就能自增，不用出包
   ============================================================ */
struct DDCategoryTab: View {
    @ObservedObject private var store = DDStore.shared
    var onOpen: (DDProduct) -> Void
    var onSearch: () -> Void

    /// 空 = 全部
    @State private var cate: String = ""
    /// 右栏顶上那排标签里选中的（空 = 不筛）
    @State private var tag: String = ""

    private var cats: [String] { ["全部"] + store.categories }

    private var byCate: [DDProduct] {
        let all = store.feed(store.live)
        guard !cate.isEmpty, cate != "全部" else { return all }
        return all.filter { $0.cate == cate }
    }
    private var list: [DDProduct] {
        guard !tag.isEmpty else { return byCate }
        return byCate.filter { $0.tags.contains(tag) }
    }
    /// 这个分类里出现过的标签（最多 8 个，拿去当子分类）
    private var chips: [String] {
        var out: [String] = []
        for p in byCate { for t in p.tags where !out.contains(t) { out.append(t) } }
        return Array(out.prefix(8))
    }

    var body: some View {
        HStack(spacing: 0) {
            /* ---------------- 左栏：分类 ---------------- */
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(cats, id: \.self) { c in
                        let on = (c == "全部" && cate.isEmpty) || c == cate
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) { cate = (c == "全部") ? "" : c; tag = "" }
                        } label: {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(on ? DDColor.red : Color.clear)
                                    .frame(width: 3, height: 15)
                                Text(Tr(c))
                                    .font(pf(13.5, on ? .semibold : .regular))
                                    .foregroundColor(on ? DDColor.red : DDColor.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, 6).padding(.trailing, 8)
                            .frame(height: 50)
                            .frame(maxWidth: .infinity)
                            .background(
                                Group {
                                    if on { DDColor.cardGrad } else { Color.clear }
                                }
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 20)
                }
            }
            /* 2026-10-17：左栏 92 → 84、右栏左右各 10 → 8，
               把省下的 12pt 全给商品卡（分类页右栏本来就窄，卡片更容易挤爆） */
            .frame(width: 84)
            .background(DDColor.page)

            /* ---------------- 右栏：搜索 + 标签 + 商品 ---------------- */
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    /* 顶上那条搜索（大商城分类页都是这么放的） */
                    Button { onSearch() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundColor(DDColor.sub)
                            Text(Tr("搜商品 / 品牌 / 分类"))
                                .font(pf(13.5)).foregroundColor(DDColor.sub)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Capsule().fill(Color.white))
                        .overlay(Capsule().stroke(DDColor.cardEdge, lineWidth: 0.6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    /* 这个分类的一句话 + 件数 */
                    HStack(spacing: 6) {
                        Text(Tr(cate.isEmpty ? "全部商品" : cate))
                            .font(pf(16, .semibold)).foregroundColor(DDColor.ink)
                        Text(String(list.count) + Tr(" 件"))
                            .font(pf(11.5)).foregroundColor(DDColor.sub)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)

                    /* 子分类标签（这个分类里出现过的标签） */
                    if !chips.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                chip(Tr("全部"), tag.isEmpty) { tag = "" }
                                ForEach(chips, id: \.self) { t in
                                    chip(Tr(t), tag == t) { tag = (tag == t) ? "" : t }
                                }
                            }
                        }
                    }

                    /* 商品双列（错落瀑布流，和首页同一套，卡片高矮不齐才有"逛"的感觉） */
                    DDWaterfallGrid(cells: list.map { p -> (view: AnyView, h: CGFloat) in
                        (view: AnyView(Button { onOpen(p) } label: { DDProductCard(product: p) }
                            .buttonStyle(.plain)),
                         h: DDWaterfallGrid.estimate(p))
                    }, spacing: 10)

                    if list.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 30)).foregroundColor(DDColor.weak)
                            Text(Tr("这个分类下暂时没有商品"))
                                .font(pf(13)).foregroundColor(DDColor.sub)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 50)
                    }

                    Spacer(minLength: 16)
                }
                /* 左右必须同值，否则整组商品卡会相对屏幕中心偏 1pt。 */
                .padding(.horizontal, 8)
                .padding(.top, 10)
            }
            .background(DDColor.page)
        }
    }

    /// 子分类胶囊：选中红底白字，没选浅底红字
    private func chip(_ text: String, _ on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { tap() } } label: {
            Text(text)
                .font(pf(12.5, on ? .medium : .regular))
                .foregroundColor(on ? .white : DDColor.red)
                .padding(.horizontal, 11).frame(height: 26)
                .background(Capsule().fill(on ? DDColor.red : DDColor.redLight))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
