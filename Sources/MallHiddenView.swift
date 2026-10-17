import SwiftUI

/* ============================================================
   不感兴趣 / 已隐藏 —— 恢复页（2026-10-16 用户：
   「客户把商品都 x 了没有恢复吗」）

   商城「我的」里多了一行「不感兴趣与隐藏」：
     · 被 × 掉（不感兴趣）的商品 → 一条一条恢复，或一键全部恢复
     · 少推的类目 → 恢复（不再沉底）
     · 被 × 掉的广告卡 → 恢复
   以前这三样里只有「类目」能恢复，而且入口藏在首页那条提示里。
   ============================================================ */

struct MallHiddenView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DDStore.shared

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("不感兴趣与隐藏"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    if store.disliked.isEmpty && store.mutedCates.isEmpty && store.hiddenAds.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "hand.thumbsup")
                                .font(.system(size: 30)).foregroundColor(C.subLabel)
                            Text(Tr("没有隐藏过任何东西")).font(pf(15)).foregroundColor(C.label)
                            Text(Tr("在商城里长按商品卡可以「不感兴趣」，点卡片右上角的 × 可以关掉广告。"))
                                .font(pf(12.5)).foregroundColor(C.subLabel).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 30)
                    } else {
                        if !store.disliked.isEmpty { dislikeCard }
                        if !store.mutedCates.isEmpty { cateCard }
                        if !store.hiddenAds.isEmpty { adCard }
                        Button {
                            store.restoreAllDisliked()
                            store.unhideAllAds()
                            app.show(Tr("已经全部恢复，商城会重新推荐"))
                        } label: {
                            Text(Tr("全部恢复"))
                                .font(pf(15.5, .medium)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(height: 46)
                                .background(RoundedRectangle(cornerRadius: 23).fill(C.green))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    Spacer().frame(height: 20)
                }
                .padding(.horizontal, 12).padding(.top, 10)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }

    private var dislikeCard: some View {
        VStack(spacing: 0) {
            head(Tr("不感兴趣的商品"), sub: String(store.disliked.count) + Tr(" 件"))
            ForEach(store.dislikedProducts) { p in
                HairLine(inset: 16)
                HStack(spacing: 12) {
                    DDThumb(em: p.em, size: 46, radius: 8, img: p.img)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.title).font(pf(13.5)).foregroundColor(C.label).lineLimit(2)
                        Text("¥" + moneyFmt(p.price)).font(pf(12.5)).foregroundColor(DDColor.red)
                    }
                    Spacer(minLength: 0)
                    Button { store.restoreDisliked(p.id); app.show(Tr("已恢复")) } label: {
                        Text(Tr("恢复")).font(pf(13, .medium)).foregroundColor(.white)
                            .padding(.horizontal, 14).frame(height: 32)
                            .background(Capsule().fill(C.green))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .background(C.cardBg).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var cateCard: some View {
        VStack(spacing: 0) {
            head(Tr("少推的类目"), sub: Tr("这些类目会沉到最后"))
            ForEach(store.mutedCates, id: \.self) { c in
                HairLine(inset: 16)
                HStack(spacing: 12) {
                    Text(Tr(c)).font(pf(14.5)).foregroundColor(C.label)
                    Spacer(minLength: 0)
                    Button { store.unmuteCate(c); app.show(Tr("已恢复")) } label: {
                        Text(Tr("恢复")).font(pf(13, .medium)).foregroundColor(.white)
                            .padding(.horizontal, 14).frame(height: 32)
                            .background(Capsule().fill(C.green))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .background(C.cardBg).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var adCard: some View {
        VStack(spacing: 0) {
            head(Tr("已经 × 掉的广告"), sub: String(store.hiddenAds.count) + Tr(" 条"))
            ForEach(store.hiddenAds, id: \.self) { key in
                HairLine(inset: 16)
                HStack(spacing: 12) {
                    Text(key.replacingOccurrences(of: "ad:", with: ""))
                        .font(pf(13)).foregroundColor(C.label).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { store.unhideAd(key); app.show(Tr("已恢复，这条广告会重新出现")) } label: {
                        Text(Tr("恢复")).font(pf(13, .medium)).foregroundColor(.white)
                            .padding(.horizontal, 14).frame(height: 32)
                            .background(Capsule().fill(C.green))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .background(C.cardBg).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func head(_ t: String, sub: String) -> some View {
        HStack(spacing: 8) {
            Text(t).font(pf(15.5, .medium)).foregroundColor(C.label)
            Text(sub).font(pf(12)).foregroundColor(C.subLabel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
