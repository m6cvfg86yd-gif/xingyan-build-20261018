import SwiftUI
import UIKit

/* ============================================================
   聊天背景 · 黑白场景的基础背景（6 张）

   · 图片放在服务器的 public/bg 下（/bg/bw1.jpg … bw6.jpg），
     想换图/加图只改服务器上的文件，不用重新出包；
   · 点一张立刻生效（写进 me.chatBackground，聊天页那一层会跟着换）；
   · 下面还留着原来那两条老入口：默认背景 / 从相册选一张。
   · **在聊天页右上「⋯」里进来时**（chatId 有值）：只改**这一个会话**的背景，
     和微信一样（微信也是「设置当前聊天背景」只对当前聊天生效，存在本机）。
   ============================================================ */

/// 每个会话单独设的聊天背景（只存本机，和微信一样）
final class ChatBgStore: ObservableObject {
    static let shared = ChatBgStore()
    /// 变了就 +1：聊天页那一层跟着刷新
    @Published private(set) var version = 0

    private func key(_ chatId: String) -> String { "chris.chatBg." + chatId }

    /// 这个会话单独设的背景（空 = 用全局的）
    func get(_ chatId: String) -> String {
        guard !chatId.isEmpty else { return "" }
        return UserDefaults.standard.string(forKey: key(chatId)) ?? ""
    }

    func set(_ chatId: String, _ value: String) {
        guard !chatId.isEmpty else { return }
        if value.isEmpty || value == "auto" {
            UserDefaults.standard.removeObject(forKey: key(chatId))
        } else {
            UserDefaults.standard.set(value, forKey: key(chatId))
        }
        version += 1
    }
}

struct ChatBackgroundSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    /// 有值 = 在某个聊天里点「⋯ → 设置当前聊天背景」进来的：只改这个会话
    var chatId: String = ""

    @State private var picking = false
    @State private var busy = false

    /// 6 张基础背景（黑白/灰阶）
    static let presets: [String] = ["/bg/bw1.jpg", "/bg/bw2.jpg", "/bg/bw3.jpg",
                                    "/bg/bw4.jpg", "/bg/bw5.jpg", "/bg/bw6.jpg"]
    /// 每张下面那行小字（方便一眼分清是哪张）
    static let names: [String] = ["浅灰渐变", "深灰渐变", "细斜纹", "细网格", "磨砂噪点", "同心圆"]

    /* 后台「聊天壁纸」页配的那一份（默认壁纸 + 基础壁纸）。
       进这一页拉一次；拉不到就用上面内置的 6 张 —— 老服务器、断网都不会白屏。 */
    @State private var remotePresets: [ChatBgPayload.Item] = []
    @State private var remoteVersion = ""

    /// 这一页真正显示的壁纸：后台配了就用后台的，没有就退回内置那 6 张
    private var shownPresets: [(path: String, name: String)] {
        let remote = remotePresets.compactMap { it -> (path: String, name: String)? in
            guard let p = it.path, !p.isEmpty else { return nil }
            return (p, it.name ?? "")
        }
        if !remote.isEmpty { return remote }
        var out: [(path: String, name: String)] = []
        for (idx, p) in Self.presets.enumerated() {
            out.append((p, Self.names[min(idx, Self.names.count - 1)]))
        }
        return out
    }

    /// 交给图片加载器之前在地址后面挂个版本号：
    /// ImageStore 是按 path 缓存的，后台换了同一路径上的图，版本号一变缓存就失效。
    /// （后台每一格基本都是「重新上传」，地址本来就是新的，所以这条主要是兜底。）
    private func versioned(_ p: String) -> String {
        guard !remoteVersion.isEmpty, !p.hasPrefix("data:") else { return p }
        return p + (p.contains("?") ? "&" : "?") + "v=" + remoteVersion
    }

    private var inChat: Bool { !chatId.isEmpty }
    @ObservedObject private var store = ChatBgStore.shared
    /// 现在选中的是哪一张（聊天里=本机给这个会话设的；全局=我资料里的）
    private var current: String {
        if inChat {
            let v = store.get(chatId)
            return v.isEmpty ? "auto" : v
        }
        return app.me?.chatBackground ?? "auto"
    }

    var body: some View {
        /* ⚠ 这一页现在是被 **push 进「我」页那条导航栈**的（设置 → 通用 → 聊天背景），
           所以里面**不能再套一层 NavigationStack** —— 两层嵌套在 iOS 上就是
           白屏 + 直接被系统干掉（用户反馈「聊天背景根本进不去、白屏后跳出」）。
           在聊天里当半屏 sheet 用时，这页自己画的 NavBar 一样正常。 */
        VStack(spacing: 0) {
            NavBar(title: Tr(inChat ? "选择背景图" : "聊天背景"), back: { dismiss() }) {
                Button { dismiss() } label: {
                    Text(Tr("完成")).font(pf(15.5)).foregroundColor(C.label)
                        .padding(.horizontal, 14).frame(height: 32)
                }
                .buttonStyle(.plain)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Tr("基础背景 · 黑白场景"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                              spacing: 12) {
                        /* 用 shownPresets：后台「聊天壁纸」页配过就用后台那几张 */
                        ForEach(Array(shownPresets.enumerated()), id: \.offset) { _, item in
                            Button { pick(item.path) } label: {
                                VStack(spacing: 5) {
                                    ZStack {
                                        RemoteImage(path: versioned(item.path), mode: .fill)
                                            .frame(width: 100, height: 148)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        if current == item.path {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(C.green, lineWidth: 2.5)
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 19))
                                                .foregroundColor(C.green)
                                                .padding(5)
                                                .frame(maxWidth: .infinity, maxHeight: .infinity,
                                                       alignment: .topTrailing)
                                        }
                                    }
                                    if !item.name.isEmpty {
                                        Text(Tr(item.name))
                                            .font(pf(11.5))
                                            .foregroundColor(C.subLabel)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)

                    Rectangle().fill(C.pageBg).frame(height: 8).padding(.top, 12)

                    VStack(spacing: 0) {
                        Button { pick("auto") } label: {
                            HStack {
                                Text(inChat ? Tr("使用全局背景") : Tr("默认背景"))
                                    .font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 0)
                                if current == "auto" {
                                    Image(systemName: "checkmark").foregroundColor(C.green)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        HairLine(inset: 16)

                        /* 「从相册选一张」**聊天里也要有**。
                           以前这一整行被 `if !inChat` 包着 —— 从「我 → 设置 → 聊天背景」
                           进来才有，从聊天页「⋯ → 选择背景图」进来（单聊、群聊都是）
                           根本看不到这一行，用户反馈的就是「群里面换不了相册背景」。
                           微信是单聊/群聊里都能从相册选，选完只对当前这个聊天生效。 */
                        Button { picking = true } label: {
                            HStack {
                                Text(Tr("从相册选一张")).font(pf(16)).foregroundColor(C.label)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(C.subLabel)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 52)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .background(C.cardBg)

                    if busy {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 14)
                    }
                }
                .padding(.bottom, 26)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .sheet(isPresented: $picking) {
            PhotoPicker { image in upload(image) }
        }
        /* 进这一页拉一次后台「聊天壁纸」配的那份（拉不到就用内置的 6 张） */
        .task { await loadRemote() }
    }

    /// 后台「聊天壁纸」页配的壁纸清单：默认壁纸 + 基础壁纸。
    /// 拉到就整页跟着后台走；拉不到（老服务器 / 断网）就保持内置那 6 张。
    private func loadRemote() async {
        guard let r = await API.shared.chatBackgrounds() else { return }
        remotePresets = r.presets ?? []
        remoteVersion = r.version ?? ""
        /* 「默认壁纸」：自己没挑过背景的人（auto）用后台配的这张。
           后台存的那一份同时会写进 branding.chatBackground，两边不会打架。 */
        if let def = r.default, !def.isEmpty, (app.me?.chatBackground ?? "auto") == "auto" {
            app.defaultChatBackground = def
        }
    }

    /// 点一张基础背景：立刻写进我的资料（聊天页那一层会重新加载）
    private func pick(_ path: String) {
        /* 聊天页进来的：只改这一个会话（存本机，和微信一样） */
        if inChat {
            ChatBgStore.shared.set(chatId, path)
            app.show(path == "auto" ? Tr("已改用全局背景") : Tr("这个聊天的背景换好了"))
            return
        }
        Task {
            busy = true
            await API.shared.changeBackground(path)
            app.me = try? await API.shared.me()
            busy = false
        }
    }

    /// 从相册选一张：原图上传 → 当成背景。
    ///
    /// 两种进来方式效果不一样（以前这里没区分，聊天里选完相册会去改**全局**背景，
    /// 也就是「换了半天，只有当前这个聊天没变，别的聊天全变了」）：
    ///   · 聊天里进来的（chatId 有值）→ 只把这张设给**当前这个会话**，存本机，和微信一样；
    ///   · 从「我 → 聊天背景」进来的 → 还是改自己的全局背景。
    private func upload(_ image: UIImage) {
        Task {
            busy = true
            if let url = try? await API.shared.uploadOriginal(image: image) {
                if inChat {
                    ChatBgStore.shared.set(chatId, url)
                    app.show(Tr("这个聊天的背景换好了"))
                } else {
                    await API.shared.changeBackground(url)
                    app.me = try? await API.shared.me()
                    app.show(Tr("聊天背景换好了"))
                }
            } else {
                app.show(Tr("图片上传失败，换一张再试"))
            }
            busy = false
        }
    }
}
