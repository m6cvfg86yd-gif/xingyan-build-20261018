import SwiftUI

/* ============================================================
   商城商品卡片（聊天里那张）—— 2026-10-15 用户：
   「商城里的分享应该是卡片可以直接跳转的」

   以前分享商品发出去的是一条**文字 + 网址**，收端只能看到一串字。
   现在发的是 kind = "mall" 的**卡片消息**：封面 + 商品名 + 价格 +
   「星言商城」小标；**点一下直接进商品详情页**（不用去浏览器）。

   · 卡片 JSON：{ id, em, img, title, price, orig, shop }（和音乐卡片一个套路）
   · 打开详情：MallSheet.shared.open(product)（在 MainTab 最外层挂一次，
     和 MusicSheet 一样 —— 聊天里点、哪一层都能弹出来）
   ============================================================ */

/// 聊天里那张商城卡片的正文（和消息 JSON 对应）
struct MallCardInfo {
    var id = ""
    var em = "📦"
    var img = ""
    var title = ""
    var price: Double = 0
    var orig: Double = 0
    var shop = ""

    init?(json: String) {
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        id = (o["id"] as? String) ?? ""
        em = (o["em"] as? String) ?? "📦"
        img = (o["img"] as? String) ?? ""
        title = (o["title"] as? String) ?? ""
        price = (o["price"] as? Double) ?? Double(o["price"] as? Int ?? 0)
        orig = (o["orig"] as? Double) ?? Double(o["orig"] as? Int ?? 0)
        shop = (o["shop"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
    }

    var asProduct: DDProduct {
        DDProduct(id: id, em: em, img: img.isEmpty ? nil : img, title: title,
                  price: price, orig: orig > 0 ? orig : price, sold: "", grp: 2,
                  tags: [], shop: shop, cate: "其它")
    }
}

/// 谁都能叫出商城商品页（聊天里点那张卡片）
@MainActor
final class MallSheet: ObservableObject {
    static let shared = MallSheet()
    @Published var open = false
    @Published var product: DDProduct?
    func open(_ p: DDProduct) { product = p; open = true }
    func close() { open = false }
}

/// 聊天里那张商品卡片
struct MallCardBubble: View {
    let info: MallCardInfo
    /// 点整张卡：进商品页
    var onOpen: () -> Void

    var body: some View {
        Button { onOpen() } label: {
            HStack(spacing: 10) {
                DDThumb(em: info.em, size: 64, radius: 6, img: info.img.isEmpty ? nil : info.img)
                VStack(alignment: .leading, spacing: 5) {
                    Text(info.title).font(pf(14.5)).foregroundColor(C.label)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("¥" + moneyFmt(info.price))
                            .font(pf(16, .semibold)).foregroundColor(DDColor.red)
                        if info.orig > info.price {
                            Text("¥" + moneyFmt(info.orig))
                                .font(pf(11.5)).foregroundColor(C.subLabel).strikethrough()
                        }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "bag.fill").font(.system(size: 9))
                        Text(DDStore.shared.mallName).font(pf(10.5))
                        if !info.shop.isEmpty {
                            Text("· " + info.shop).font(pf(10.5)).lineLimit(1)
                        }
                    }
                    .foregroundColor(C.subLabel)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: 260, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(C.hairline, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
