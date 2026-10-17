import SwiftUI

/* ============================================================
   朋友圈的评论输入条（2026-10-12 加，照微信）

   微信里点「评论」**不弹框**：从底下滑出一条输入条（浮在键盘上方），
   左边是输入框、右边是「发送」；点别人的评论会带上「回复 A：」。
   我们以前用的是系统 .alert（跳个框），用户要求对齐微信，所以做成这条。

   浮在键盘上方靠 safeAreaInset(edge: .bottom)：系统会把键盘算进安全区。
   ============================================================ */

struct MomentCommentBar: View {
    @Binding var text: String
    /// 回复谁的名字（空 = 直接评论）
    var replyTo: String = ""
    let onSend: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            TextField(replyTo.isEmpty ? Tr("评论") : (Tr("回复 ") + replyTo + "："),
                      text: $text, axis: .vertical)
                .font(pf(15.5))
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.fieldBg))
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { if canSend { onSend() } }

            Button { onSend() } label: {
                Text(Tr("发送"))
                    .font(pf(15.5, .medium))
                    .foregroundColor(canSend ? C.green : C.subLabel)
                    .frame(height: 36)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)

            Button { onCancel() } label: {
                Text(Tr("取消"))
                    .font(pf(15.5))
                    .foregroundColor(C.subLabel)
                    .frame(height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(C.cardBg)
        .overlay(alignment: .top) { HairLine() }
        .task {
            /* 稍微等一下再聚焦：输入条刚插进布局就 focus，键盘有时候不弹 */
            try? await Task.sleep(nanoseconds: 150_000_000)
            focused = true
        }
    }
}
