import SwiftUI

/* ============================================================
   直播专场（发现 → 直播专场）
   没有真视频（内网演示服跑不动推流），但「谁在看、谁在说话、多少赞」全是真的：
     · 房间名单在服务器的 data/live.json（后台可直接改）
     · 进房间上报，在线人数实时同步（长连接广播）
     · 弹幕、点赞都是实时的：同房间的人会立刻看到
   ============================================================ */

struct LiveRoom: Decodable, Identifiable, Hashable {
    struct Host: Decodable, Hashable {
        var id: String?
        var name: String?
        var avatar: String?
    }
    var id: String
    var title: String?
    var tag: String?
    var cover: String?
    var status: String?
    var hot: Int?
    var watching: Int?
    var likes: Int?
    /// 主播正在推流（有画面可看）
    var streaming: Bool?
    var hostId: String?
    var host: Host?

    var isLive: Bool { (status ?? "live") == "live" }
    var hostName: String { host?.name ?? "主播" }
    var hostAvatar: String { host?.avatar ?? "" }
}

/* 直播房间不需要额外的 decodable：API 里那几个方法只用得到 LiveRoom */

/* ---------------------------------------------------------- 房间列表 */

struct LiveListView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var rooms: [LiveRoom] = []
    @State private var loading = true

    private let pageBg = Color.dyn(0x111111, 0x141419)
    private let cardBg = Color(hex: 0x1B1B1D)
    private let ink = Color.white
    private let subInk = Color(hex: 0x929292)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(Tr("直播专场")).font(pf(17, .semibold)).foregroundColor(ink)
                HStack(spacing: 0) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(ink)
                            .frame(width: 44, height: L.navH)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: L.navH)
            .background(pageBg)

            ScrollView {
                LazyVStack(spacing: 12) {
                    if loading && rooms.isEmpty {
                        ProgressView().tint(.white).padding(.top, 60)
                    } else if rooms.isEmpty {
                        Text(Tr("还没有直播间"))
                            .font(pf(14)).foregroundColor(subInk).padding(.top, 70)
                    } else {
                        ForEach(rooms) { r in
                            NavigationLink(value: r) { roomCard(r) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .swipeBack { dismiss() }
        .navigationDestination(for: LiveRoom.self) { r in
            LiveRoomView(room: r)
        }
        .task {
            rooms = (try? await API.shared.liveRooms()) ?? []
            loading = false
        }
    }

    private func roomCard(_ r: LiveRoom) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(r.isLive
                          ? LinearGradient(colors: [Color(hex: 0x2B3A55), Color(hex: 0x14161C)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                          : LinearGradient(colors: [Color(hex: 0x222225), Color(hex: 0x191919)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 132)
                if !(r.cover ?? "").isEmpty {
                    RemoteImage(path: r.cover ?? "").frame(height: 132).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                HStack(spacing: 6) {
                    if r.isLive {
                        Text(Tr("直播中"))
                            .font(pf(11, .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color(hex: 0xFA5151)))
                    } else {
                        Text(Tr("预告"))
                            .font(pf(11, .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color(white: 1, opacity: 0.22)))
                    }
                    if !(r.tag ?? "").isEmpty {
                        Text(r.tag ?? "")
                            .font(pf(11)).foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color(white: 0, opacity: 0.35)))
                    }
                    Spacer(minLength: 0)
                    if r.isLive {
                        Text("\(r.watching ?? 0) 人在看")
                            .font(pf(11)).foregroundColor(.white.opacity(0.9))
                    }
                }
                .padding(10)
            }
            HStack(spacing: 9) {
                Avatar(path: r.hostAvatar, size: 34, radius: 17, circle: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title ?? "")
                        .font(pf(15, .medium)).foregroundColor(ink).lineLimit(1)
                    Text(r.isLive ? "\(r.hostName) · \(r.hot ?? 0) 热度" : "\(r.hostName) · 待开播")
                        .font(pf(12.5)).foregroundColor(subInk).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardBg))
    }
}

/* ---------------------------------------------------------- 直播间 */

struct LiveRoomView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let room: LiveRoom
    @ObservedObject private var live = LiveCenter.shared

    @State private var danmakus: [(who: String, text: String)] = []
    @State private var draft = ""
    @State private var watching = 0
    @State private var likes = 0
    /// 退出前确认（抖音会问一句）
    @State private var confirmExit = false
    @State private var hearts: [UUID] = []

    @ObservedObject private var realtime = Realtime.shared

    var body: some View {
        ZStack {
            /* 背景：拿主播头像糊一层（和通话页一个做法），没有就用深色渐变 */
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1B2233), Color(hex: 0x0C0C0E)],
                               startPoint: .top, endPoint: .bottom)
                if !room.hostAvatar.isEmpty {
                    RemoteImage(path: room.hostAvatar).blur(radius: 55).scaleEffect(1.4).opacity(0.6)
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                navBar
                Spacer(minLength: 0)
                danmakuList
                bottomBar
            }

            /* 真视频层：观众看到主播画面；主播看到自己的预览（右下小窗） */
            if live.watching, live.remoteVideo != nil {
                VideoSurface(track: live.remoteVideo)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            } else if live.publishing, live.localVideo != nil {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VideoSurface(track: live.localVideo)
                            .frame(width: 104, height: 148)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .padding(.trailing, 14)
                            .padding(.bottom, 120)
                    }
                }
                .allowsHitTesting(false)
            }
            if live.watching, live.remoteVideo == nil {
                VStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text(Tr("正在连主播的画面…")).font(pf(14)).foregroundColor(.white.opacity(0.8))
                }
            }

            /* 点赞飘心 */
            ForEach(hearts, id: \.self) { id in
                FloatingHeart(id: id)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .hidesTabBar()
        .swipeBack { dismiss() }
        /* 抖音那套：双击屏幕点赞（连点就飘心），退出前问一句 */
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            like()
            popHeart()
        })
        .confirmationDialog(Tr("确定要退出直播吗？"), isPresented: $confirmExit, titleVisibility: .visible) {
            Button(Tr("退出直播"), role: .destructive) { dismiss() }
            Button(Tr("继续观看"), role: .cancel) { }
        }
        .onChange(of: realtime.event) { ev in
            guard ev.type == "live", ev.roomId == room.id else { return }
            switch ev.liveAction {
            case "danmaku":
                if !ev.liveText.isEmpty {
                    danmakus.append((ev.liveFrom.isEmpty ? "观众" : ev.liveFrom, ev.liveText))
                    if danmakus.count > 60 { danmakus.removeFirst(danmakus.count - 60) }
                }
            case "count":
                watching = ev.watching
            case "like":
                likes = ev.likes
                popHeart()
            default:
                break
            }
        }
        .task {
            watching = (try? await API.shared.liveJoin(room.id)) ?? 0
            likes = room.likes ?? 0
            danmakus.append(("系统", "欢迎来到「\(room.title ?? "直播间")」，友善聊天哦～"))
            /* 不是我的房间、而且主播在推流 → 自动看画面 */
            let isMine = (room.host?.id ?? "") == (app.me?.id ?? "-")
            if !isMine, let hid = room.host?.id, !hid.isEmpty, room.streaming == true {
                live.startWatch(room: room.id, host: hid)
            }
        }
        .onDisappear {
            live.stopWatch()
            Task { await API.shared.liveLeave(room.id) }
        }
    }

    private var navBar: some View {
        HStack(spacing: 10) {
            Button { confirmExit = true } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 40, height: L.navH)
            }
            .buttonStyle(.plain)
            Avatar(path: room.hostAvatar, size: 30, radius: 15, circle: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(room.hostName).font(pf(14, .medium)).foregroundColor(.white)
                Text(room.isLive ? "\(watching) 人在看" : "未开播")
                    .font(pf(11.5)).foregroundColor(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
            Text("❤️ \(likes)")
                .font(pf(13)).foregroundColor(.white.opacity(0.9))
            /* 我的房间：给一个开播/结束的按钮 */
            if isMyRoom {
                Button {
                    Task {
                        if live.publishing {
                            live.stopPublish()
                        } else {
                            let ok = await live.startPublish(room: room.id)
                            if !ok { app.show(Tr("要相机和麦克风权限才能开播")) }
                        }
                    }
                } label: {
                    Text(live.publishing ? "结束直播" : "开始直播")
                        .font(pf(13, .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(live.publishing ? Color(hex: 0xFA5151) : C.green))
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
        }
        .padding(.trailing, 14)
        .frame(height: L.navH)
        .background(Color.black.opacity(0.25))
    }

    private var isMyRoom: Bool { (room.host?.id ?? "") == (app.me?.id ?? "-") }

    private var danmakuList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(danmakus.suffix(9), id: \.text.hashValue) { d in
                HStack(alignment: .top, spacing: 6) {
                    Text(d.who)
                        .font(pf(12.5, .medium))
                        .foregroundColor(Color(hex: 0x7FD3FF))
                    Text(d.text)
                        .font(pf(13))
                        .foregroundColor(.white.opacity(0.95))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.28)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            TextField("", text: $draft, prompt: Text(Tr("说点什么…")).foregroundColor(.white.opacity(0.5)))
                .font(pf(14))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Capsule().fill(Color(white: 1, opacity: 0.14)))
                .onSubmit { send() }
            Button { send() } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(C.green))
            }
            .buttonStyle(.plain)
            Button { like() } label: {
                Image(systemName: "heart.fill")
                    .font(.system(size: 17))
                    .foregroundColor(Color(hex: 0xFF5A7A))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color(white: 1, opacity: 0.14)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, max(10, L.safeBottom))
        .background(Color.black.opacity(0.35))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task {
            do { try await API.shared.liveDanmaku(room.id, text: text) }
            catch { app.show((error as? APIError)?.errorDescription ?? "发不出去") }
        }
    }

    private func like() {
        popHeart()
        Task { _ = try? await API.shared.liveLike(room.id) }
    }

    private func popHeart() {
        let id = UUID()
        hearts.append(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            hearts.removeAll { $0 == id }
        }
    }
}

/// 点赞飘上去的小心心
struct FloatingHeart: View {
    let id: UUID
    @State private var up = false
    @State private var side: CGFloat = Bool.random() ? 1 : -1

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 22))
            .foregroundColor(Color(hex: 0xFF5A7A))
            .offset(x: L.width / 2 - 46 + (up ? side * 26 : 0), y: up ? -260 : -60)
            .opacity(up ? 0 : 0.95)
            .onAppear {
                withAnimation(.easeOut(duration: 1.5)) { up = true }
            }
    }
}
