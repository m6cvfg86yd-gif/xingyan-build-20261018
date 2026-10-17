import Foundation

/* ============================================================
   我的表情库（微信「我 → 表情」那套的本地那一半）

   微信的逻辑：
     · 商店里一包一包摆着，点「添加」进我的表情，点「移除」拿掉
     · 我的表情里有什么，聊天表情面板底下那排就有哪几包，点一下切到那一包
   这里把「我添加了哪些包」存在本机（内置的那些包用 b1…b14 做 id），
   服务端下发的表情包仍然照旧走 /api/stickers。
   ============================================================ */

enum StickerLib {
    private static let key = "sticker.installed.builtin"

    /// 我添加过的内置表情包 id（顺序就是面板底下的顺序）
    static var ids: [String] {
        get { (UserDefaults.standard.array(forKey: key) as? [String]) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func isIn(_ id: String) -> Bool { ids.contains(id) }

    static func add(_ id: String) {
        var list = ids
        if !list.contains(id) { list.append(id) }
        ids = list
    }

    static func remove(_ id: String) {
        ids = ids.filter { $0 != id }
    }

    static func toggle(_ id: String) {
        if isIn(id) { remove(id) } else { add(id) }
    }

    /// 我添加过的内置包（按 id 的添加顺序）
    static var mine: [BuiltinPack] {
        let order = ids
        return order.compactMap { id in BuiltinPacks.all.first(where: { $0.id == id }) }
    }

    /// 还没添加的内置包（商店里显示「添加」的那些）
    static var shop: [BuiltinPack] {
        BuiltinPacks.all.filter { !isIn($0.id) }
    }

    /* ---------------- 图库里那些包（emoji/ap1 那套图片表情） ---------------- */

    private static let remoteKey = "sticker.installed.remote"

    /// 我添加过的图库表情包 id
    static var remoteIds: [String] {
        get { (UserDefaults.standard.array(forKey: remoteKey) as? [String]) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: remoteKey) }
    }

    static func isRemoteIn(_ id: String) -> Bool { remoteIds.contains(id) }

    static func addRemote(_ id: String) {
        var list = remoteIds
        if !list.contains(id) { list.append(id) }
        remoteIds = list
    }

    static func removeRemote(_ id: String) {
        remoteIds = remoteIds.filter { $0 != id }
    }

}
