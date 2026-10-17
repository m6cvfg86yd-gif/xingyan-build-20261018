import SwiftUI

/* ============================================================
   滚动歌词（2026-10-15 对齐 QQ音乐）

   曲库里每首歌都有 `lyrics` 字段（后台贴 LRC 或一行一句都行），这一页把它解析出来：
     · 逐行高亮（按播放进度）、当前行自动居中
     · 点某一行 → 跳到那一句（QQ音乐也是这样）
     · 没有歌词 / 解析不出来 → 显示占位，不空白
   解析支持标准 LRC（[mm:ss.xx]），也支持一行一句的纯文本（按行平均分配时间）。
   ============================================================ */

enum MusicLRC {
    /// 解析 LRC / 纯文本 → [(开始秒数, 这一行)]
    static func parse(_ raw: String?, duration: Double = 0) -> [(t: Double, text: String)] {
        guard let raw = raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var out: [(Double, String)] = []
        let re = try? NSRegularExpression(pattern: "\\[(\\d{1,2}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]", options: [])
        for line in raw.components(separatedBy: .newlines) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            if let re = re {
                let ns = s as NSString
                let ms = re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
                if !ms.isEmpty {
                    let text = ns.replacingCharacters(in: ms.first!.range, with: "")
                        .trimmingCharacters(in: .whitespaces)
                    for m in ms {
                        let mi = Int(ns.substring(with: m.range(at: 1))) ?? 0
                        let se = Int(ns.substring(with: m.range(at: 2))) ?? 0
                        var frac = 0.0
                        if m.range(at: 3).location != NSNotFound {
                            let f = ns.substring(with: m.range(at: 3))
                            frac = (Double(f) ?? 0) / pow(10.0, Double(f.count))
                        }
                        out.append((Double(mi) * 60 + Double(se) + frac, text))
                    }
                    continue
                }
            }
            /* 没有时间标签：当成一行一句，稍后按顺序均分（去掉 LRC 的元信息行） */
            if s.hasPrefix("[ti:") || s.hasPrefix("[ar:") || s.hasPrefix("[al:") || s.hasPrefix("[by:") { continue }
            out.append((-1, s))
        }
        var list = out.sorted { $0.0 < $1.0 }
        /* 全是 -1（纯文本）就按总时长平均铺开 */
        if list.allSatisfy({ $0.0 < 0 }) {
            let d = duration > 1 ? duration : Double(list.count) * 4
            let step = d / Double(max(1, list.count))
            list = list.enumerated().map { (Double($0.offset) * step, $0.element.1) }
        }
        return list.map { (t: max(0, $0.0), text: $0.1) }
    }

    /// 当前唱到第几句（-1 = 还没到第一句）
    static func index(at seconds: Double, in lines: [(t: Double, text: String)]) -> Int {
        var idx = -1
        for (i, l) in lines.enumerated() where l.t <= seconds + 0.15 { idx = i }
        return idx
    }
}

/// 滚动歌词（放播放页里用；外部给歌词和进度，改动只通过 onSeek 回传）
struct LyricsView: View {
    let raw: String?
    /// 现在播到第几秒
    let seconds: Double
    /// 总时长（纯文本歌词按它均分）
    var duration: Double = 0
    /// 点某一行 → 跳过去
    var onSeek: (Double) -> Void

    private var lines: [(t: Double, text: String)] { MusicLRC.parse(raw, duration: duration) }

    var body: some View {
        let ls = lines
        if ls.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 30, weight: .light)).foregroundColor(C.subLabel.opacity(0.7))
                Text(Tr("暂无歌词")).font(pf(13.5)).foregroundColor(C.subLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        Spacer().frame(height: 26)
                        ForEach(ls.indices, id: \.self) { i in
                            let cur = MusicLRC.index(at: seconds, in: ls)
                            Text(ls[i].text.isEmpty ? "♪" : ls[i].text)
                                .font(pf(i == cur ? 16.5 : 15, i == cur ? .semibold : .regular))
                                .foregroundColor(i == cur ? C.label : C.subLabel)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .id(i)
                                .contentShape(Rectangle())
                                /* ⚠ 用 highPriorityGesture：这一页有时候是放在"点一下翻转"的
                                   大卡背面的，普通 onTapGesture 会被外层那颗 tap 抢走 → 点了不跳。 */
                                .highPriorityGesture(TapGesture().onEnded { onSeek(ls[i].t) })
                        }
                        Spacer().frame(height: 90)
                    }
                    .padding(.horizontal, 22)
                }
                .onChange(of: MusicLRC.index(at: seconds, in: ls)) { i in
                    guard i >= 0 else { return }
                    withAnimation(.easeInOut(duration: 0.28)) { proxy.scrollTo(i, anchor: .center) }
                }
            }
        }
    }
}
