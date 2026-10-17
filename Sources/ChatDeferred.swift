import SwiftUI

/* ============================================================
   聊天页「先占位、后渲染」的外罩 —— 2026-10-13

   为什么需要它（这次终于定性了）：
     ChatDetailView 是个**超大视图**，第一次求值（body → 布局 → 提交首帧）在慢一点的机器上
     可能要十几秒。而「点会话进聊天」属于系统的**场景更新（页面切换）**，那一小段时间有
     **看门狗**盯着：超时就直接 SIGKILL 掉进程。
     于是日志里永远只有「聊天页 8 准备打开 …」，没有「9 页面出现」，没有崩溃栈，
     内存也不大（App 40~50MB、系统还剩 6GB）—— 历史上「改一点就挂、退回去就好」，
     就是因为这点余量太薄：任何让首帧稍微重一点点的改动都会越线。

   办法（不动聊天页本身）：
     push 的时候先只渲染一个**很轻的占位**（一步就画完，切换动画稳稳过掉），
     等 0.4 秒过渡结束，再把真正的大视图塞进去 —— 那时看门狗那一段已经过去了。
     ⚠ 聊天页那个文件保持 B218 原样（一字不差），这里只是在它外面套一层。
   ============================================================ */

struct DeferredChatView: View {
    @EnvironmentObject private var app: AppState
    /// 阅后即焚的焚烧动画（放在这一层画，不往聊天页里加视图）
    @ObservedObject private var burnFX = BurnFX.shared
    let chat: Chat
    @State private var ready = false

    var body: some View {
        ZStack {
            C.pageBg.ignoresSafeArea()
            if ready {
                ChatDetailView(chat: chat)
                    .transition(.opacity)
            } else {
                /* ⚠ 2026-10-13 用户反馈「不闪退但是有个圈加载一下」：
                   占位不再画转圈 —— 就铺**这个会话自己的聊天背景**（和真页面同一张底），
                   转场过来看到的就是聊天背景，然后消息直接出现，中间没有任何"加载中"的观感。
                   （这一步同样很轻：一层底色 + 一张已经在本机缓存里的背景图。） */
                chatBackdrop
                    .ignoresSafeArea()
            }
            /* 焚毁那一下：1.1 秒的暖光 + 火星从下往上扫过（Canvas 一层画完，很轻） */
            if burnFX.firing {
                FlameSweepOverlay()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .task {
            guard !ready else { return }
            /* 0.35 秒：足够让 push 的转场动画走完（系统那一段看门狗就是盯这个），
               又不至于让人等得出来 */
            try? await Task.sleep(nanoseconds: 350_000_000)
            withAnimation(.easeOut(duration: 0.16)) { ready = true }
        }
    }

    /// 占位用的背景：和 ChatDetailView 里那套一样（本机设的 → 服务器默认 → 空白）
    @ViewBuilder private var chatBackdrop: some View {
        ZStack {
            C.pageBg
            if !bgPath.isEmpty {
                RemoteImage(path: bgPath)
                    .id(bgPath)
            }
        }
    }

    private var bgPath: String {
        let per = ChatBgStore.shared.get(chat.id)
        if !per.isEmpty { return per == "auto" ? "" : per }
        let v = app.me?.chatBackground ?? "auto"
        if v.isEmpty || v == "auto" {
            let def = app.defaultChatBackground
            return def == "auto" ? "" : def
        }
        return v
    }
}
