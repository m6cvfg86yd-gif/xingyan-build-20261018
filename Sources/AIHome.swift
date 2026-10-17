import SwiftUI

/* ============================================================
   AI 助手（「眼睛」那个号）的首页
   照用户给的那张图（ChatGPT 那种首页）做：
     · 一句「有什么我能帮你的吗？」
     · 「为你推荐」几条（后台 aiHomeSuggestions 可配，逗号分隔）
     · 下面一排四颗：对话 / 打电话 / AI 创作 / 拍题答疑

   ⚠ 这块**不能放进聊天页**。ChatDetailView 那个巨型视图只要再多一层 VStack / 新
   sheet / 新 overlay，用户一进聊天就被系统杀掉（B127 / B129 / B133 / B144 全是这么
   挂的，日志停在「8 准备打开」没有「9 页面出现」）。
   所以它住在**聊天信息页**里（GroupInfoView.swift 的 DirectChatInfoView）：在那一页点
   一条推荐 = 直接把这句话发进这个 AI 会话，然后退回聊天页自己聊。
   ============================================================ */

struct AIHomeCardView: View {
    /// 这个 AI 会话（发送就用它的 id）
    let chat: Chat
    /// 点一条推荐 / 点「AI 创作 / 拍题答疑」：把这句话发进去（空串 = 只想打字，回聊天页）
    var onSend: (String) -> Void
    /// 点「打电话」→ 走 AI 通话
    var onCall: () -> Void

    private var suggestions: [String] {
        let raw = UIConfig.text("aiHomeSuggestions",
            "上传照片 · 生成真实 3D 建模,帮我规划一个 App 的开发流程,调整动漫头像适配社交平台尺寸,设计含 5 个元素的简单创意标识")
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var acts: [(String, String)] {
        [("对话", "bubble.left.and.bubble.right.fill"),
         ("打电话", "phone.fill"),
         ("AI 创作", "wand.and.stars"),
         ("拍题答疑", "camera.viewfinder")]
    }

    var body: some View {
        PanelCard {
            VStack(spacing: 0) {
                Text(Tr("有什么我能帮你的吗？"))
                    .font(pf(19, .semibold))
                    .foregroundColor(C.label)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)

                HStack {
                    Text(Tr("为你推荐")).font(pf(13)).foregroundColor(C.subLabel)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 2)

                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { i, s in
                        if i > 0 { HairLine(inset: 44) }
                        Button { onSend(s) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(C.green)
                                    .frame(width: 22)
                                Text(s)
                                    .font(pf(15))
                                    .foregroundColor(C.label)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(C.subLabel)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 50)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                HairLine(inset: 0)

                /* 底下那四颗（图里就是图标在上、字在下，一行四等分） */
                HStack(spacing: 0) {
                    ForEach(Array(acts.enumerated()), id: \.offset) { _, a in
                        Button {
                            switch a.0 {
                            case "打电话": onCall()
                            case "对话":   onSend("")
                            case "AI 创作": onSend(Tr("帮我创作一张图片"))
                            default:        onSend(Tr("帮我解这道题"))
                            }
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: a.1)
                                    .font(.system(size: 19))
                                    .foregroundColor(C.label)
                                Text(Tr(a.0))
                                    .font(pf(11.5))
                                    .foregroundColor(C.subLabel)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
