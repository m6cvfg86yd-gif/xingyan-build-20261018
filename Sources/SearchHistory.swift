import Foundation

/* ============================================================
   搜索历史（搜索页「搜索历史」那一块用）

   · 只存本机（UserDefaults），不上传服务器
   · 最多 20 条，最近搜的排最前
   · 重复的自动去重（把旧的挪到最前，而不是存两条）
   · 清空就是一次性删除
   ============================================================ */
enum SearchHistory {
    private static let key = "chris.searchHistory"
    private static let max = 20

    /// 全部历史（最近搜的在最前）
    static var all: [String] {
        (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
    }

    /// 记一条（去重 + 挪到最前 + 截到 20 条）
    static func add(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard w.count >= 1 else { return }
        var list = all.filter { $0 != w }
        list.insert(w, at: 0)
        if list.count > max { list = Array(list.prefix(max)) }
        UserDefaults.standard.set(list, forKey: key)
    }

    /// 删一条（微信里长按/右侧小叉删单条）
    static func remove(_ word: String) {
        UserDefaults.standard.set(all.filter { $0 != word }, forKey: key)
    }

    /// 清空
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/* ============================================================
   「猜你想搜」

   · 后台可以配一组词（后台「界面配置」里加，App 进搜索页时拉一次）
   · 拉不到就用内置这组兜底 —— 服务器挂了、断网了照样能显示
   · 只做展示 + 点击填入搜索框，不涉及隐私
   ============================================================ */
enum SearchSuggest {
    /// 内置兜底（后台配了就用后台的）
    static let fallback = ["朋友圈", "聊天记录", "公众号", "视频号", "附近的人", "群聊"]

    /// 后台配置（App 启动/进搜索页时拉下来存这里）
    static var remote: [String] = []

    /// 实际展示：后台有就用后台的，没有用内置
    static var shown: [String] {
        let r = remote.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return r.isEmpty ? fallback : r
    }
}
