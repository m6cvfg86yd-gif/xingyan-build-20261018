import SwiftUI

/* ============================================================
   系统通知号（「星言团队」）的卡片 —— 排版照微信那个「微信团队」：
   标题独占一行 → 一条细线 → 正文 → 一条细线 → 「查看详情 ›」
   点整张卡进一整页看全文（复用群公告那一页）。
   ============================================================ */

struct SysNoticeInfo {
    var title = ""
    var text = ""

    init?(json: String) {
        guard let d = json.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let t = (o["title"] as? String) ?? ""
        let b = (o["text"] as? String) ?? ""
        guard !t.isEmpty || !b.isEmpty else { return nil }
        title = t.isEmpty ? Tr("通知") : t
        text = b
    }

    /// 一整页里显示的全文（标题 + 正文）
    var fullText: String {
        text.isEmpty ? title : (title + "\n\n" + text)
    }
    /// 会话列表里那一行的预览（千万别显示 JSON）
    var preview: String { text.isEmpty ? title : text }
}

struct SysNoticeBubble: View {
    let info: SysNoticeInfo
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            /* 标题独占一行，下面一条细线 —— 微信那个「微信团队」卡片就是这么排的 */
            Text(info.title)
                .font(pf(16, .medium))
                .foregroundColor(C.label)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13).padding(.vertical, 11)

            HairLine(inset: 0)

            if !info.text.isEmpty {
                Text(info.text)
                    .font(pf(15))
                    .foregroundColor(C.label.opacity(0.9))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13).padding(.vertical, 11)

                HairLine(inset: 0)
            }

            HStack(spacing: 4) {
                Text(Tr("查看详情")).font(pf(15))
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundColor(Color(hex: 0x576B95))
            .padding(.horizontal, 13).padding(.vertical, 10)
        }
        .frame(width: 252, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(C.hairline, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }
}
