import SwiftUI

/// 每条消息在屏幕上的位置（长按弹的小方框靠它贴到那条消息旁边）
///
/// ⚠ 这里刻意用「普通类」而不是 PreferenceKey + @State：
///   以前每行都往上一层层报位置，父视图收到就写 @State，列表一滚动就变成
///   「改状态 → 整页重绘 → 位置又变 → 再改状态」的死循环 ——
///   客户反馈的「消息一多就不丝滑」主要就是它。
///   现在位置只记在这个普通对象里（长按的时候读一下），完全不触发重绘。
final class MsgFrameBox {
    var frames: [String: CGRect] = [:]
}

/// 老的名字留着，避免别的地方还在引用（现在没人用了）
/// 正文（@ 和网址）解析结果的小缓存：同一条消息不重复解析。
/// 消息一多时，往上翻来翻去每条都要重新扫一遍正文，这是个大头。
enum RichBodyCache {
    private static var store: [String: AttributedString] = [:]

    static func get(_ key: String) -> AttributedString? { store[key] }

    static func put(_ key: String, _ value: AttributedString) {
        if store.count > 600 { store.removeAll(keepingCapacity: true) }
        store[key] = value
    }
}

struct MsgFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { a, _ in a }
    }
}
