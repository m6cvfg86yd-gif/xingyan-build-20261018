import SwiftUI

/* ============================================================
   聊天里的「笔记」卡片（2026-10-12 加）

   微信的逻辑：收藏里的笔记可以「转发给朋友 / 发送到聊天」，
   对面收到的是**一张笔记卡片**（不是一大段文字）—— 点开才看全文。

   所以我们加了一个消息类型 kind = "note"，content 就是笔记正文
   （里面 [图]路径 那几行照样会画成图片）。这一页是纯展示 + 一个自己的
   sheet（不碰聊天页那套巨型结构，避免又被系统杀）。
   ============================================================ */

struct NoteCardBubble: View {
    /// 笔记正文
    let text: String
    var mine: Bool
    var showTail: Bool
    var seed: Double

    @State private var open = false

    private var title: String {
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        let t = first.hasPrefix("[图]") ? "图片" : first
        return String(t.prefix(24))
    }
    private var preview: String {
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("[图]") { lines.append("［图片］"); continue }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
            if lines.count >= 4 { break }
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        Button { open = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(C.green)
                    Text(Tr("笔记"))
                        .font(pf(12.5, .medium))
                        .foregroundColor(C.green)
                    Spacer(minLength: 0)
                }
                Text(title.isEmpty ? Tr("笔记") : title)
                    .font(pf(15, .medium))
                    .foregroundColor(C.label)
                    .lineLimit(1)
                Text(preview)
                    .font(pf(13))
                    .foregroundColor(C.subLabel)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 232, alignment: .leading)
            .background(Color.dyn(0xFFFFFF, 0x1F1F22))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(C.hairline, lineWidth: 0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $open) {
            NoteViewerSheet(text: text)
        }
    }
}

/// 点开笔记卡片：全文（含插入的图片）+ 复制
struct NoteViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    @State private var copied = false
    /// 点笔记里的图看大图（overlay，不挂全屏 cover）
    @State private var viewerPath: String?

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("笔记"), back: { dismiss() }) {
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Text(copied ? Tr("已复制") : Tr("复制"))
                        .font(pf(15, .medium)).foregroundColor(C.green)
                        .padding(.horizontal, 14).frame(height: 32)
                }
                .buttonStyle(.plain)
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        if line.hasPrefix("[图]") {
                            /* 笔记里插的图：按原比例铺满一行（以前只给 maxWidth 没给高度，
                               GeometryReader 量出来是 0，图等于没显示） */
                            NoteImageBlock(path: String(line.dropFirst(3))) { p in viewerPath = p }
                        } else if !line.isEmpty {
                            Text(line)
                                .font(pf(16))
                                .foregroundColor(C.label)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(14)
                .background(C.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 12)
                Spacer().frame(height: 30)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .overlay {
            if let p = viewerPath, !p.isEmpty {
                PhotoPager(paths: [p], startIndex: 0, showActions: true) { viewerPath = nil }
            }
        }
    }
}

/* ---------------------------------------------------------------
   笔记里插进去的一张图（收藏的笔记详情、聊天里的笔记卡片、写笔记的编辑区都用它）：
   · 按宽度铺满、高度按原比例算（最高 360，太长的图不占满一屏）
   · 点一下放大看（复用 App 里那套大图翻页）
   ⚠ 以前是 RemoteImage(...).scaledToFit().frame(maxWidth: .infinity)：
     RemoteImage 里面是 GeometryReader，只给 maxWidth 不给高度时它量出来是 0，
     图就"看不见"了 —— 用户看到的就只剩正文里那行 [图]路径。
   --------------------------------------------------------------- */
struct NoteImageBlock: View {
    let path: String
    /// 点一下要干什么（给空就不响应 —— 由外面的页面自己用 overlay 弹大图）。
    /// ⚠ 这里**不能**自己挂 fullScreenCover：这一块也会出现在聊天页那一层，
    /// 在聊天页挂全屏 cover 会让那一页一打开就被系统杀掉。
    var onTap: ((String) -> Void)? = nil

    @State private var height: CGFloat = 210

    var body: some View {
        RemoteImage(path: path, mode: .fill, maxSide: 1400) { img in
            /* 图解码出来之后按真实比例定高：短边铺满、长图不超 360 */
            let w = max(120, L.width - 52)
            let ratio = img.size.height / max(1, img.size.width)
            height = min(360, max(120, w * ratio))
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { onTap?(path) }
    }
}
