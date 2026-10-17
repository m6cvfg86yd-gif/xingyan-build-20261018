import Foundation
import SwiftUI

/* ============================================================
   表情图库（服务器上的 /emoji/packs.json）

   这一份是「所有表情包」的总目录：一包一包摆着，每包有分类、
   名字、封面和图片文件名。App 拉一次缓在本机；「我添加了哪些包」
   存在本机（StickerLib），面板底下那排按它来排。
   ============================================================ */

struct RemoteStickerPack: Decodable, Hashable, Identifiable {
    var id: String
    var name: String
    var category: String
    /// 这一包图片所在目录（相对站根）：emoji/ap1
    var dir: String
    /// 封面（相对站根）：emoji/ap1/1.png
    var icon: String
    var files: [String]

    /// 这一包全部的图（相对路径，交给 assetURL 拼成 https://服务器/...）
    var paths: [String] { files.map { dir + "/" + $0 } }
}

struct StickerCategory: Decodable, Hashable, Identifiable {
    var id: String
    var name: String
}

private struct StickerCatalogPayload: Decodable {
    var categories: [StickerCategory]?
    var packs: [RemoteStickerPack]?
}

@MainActor
final class StickerCatalog: ObservableObject {
    static let shared = StickerCatalog()

    @Published private(set) var categories: [StickerCategory] = []
    @Published private(set) var packs: [RemoteStickerPack] = []
    @Published private(set) var loading = false
    private var loaded = false

    /// 拉一次就够（目录很少变；换包的时候重开 App 就行）
    func loadIfNeeded() async {
        if loaded || loading { return }
        loading = true
        defer { loading = false }
        guard let url = API.shared.assetURL("emoji/packs.json"),
              let data = try? await API.shared.assetData(url),
              let p = try? JSONDecoder().decode(StickerCatalogPayload.self, from: data) else { return }
        categories = p.categories ?? []
        packs = p.packs ?? []
        loaded = true
    }

    func packs(in category: String) -> [RemoteStickerPack] {
        packs.filter { $0.category == category }
    }

    func search(_ keyword: String) -> [RemoteStickerPack] {
        let k = keyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return packs }
        return packs.filter { $0.name.localizedCaseInsensitiveContains(k) }
    }
}

/// 面板里的一包：可能是内置的（emoji），也可能是图库里下载的（图片）
struct PanelPack: Identifiable {
    let id: String
    let name: String
    /// emoji 或者图片路径（相对站根）
    let icon: String
    /// emoji 或者图片路径
    let stickers: [String]
    let isImage: Bool
}
