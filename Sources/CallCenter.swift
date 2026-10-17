import Foundation
import AVFoundation
import AudioToolbox
import UIKit
import Combine
import WebRTC
import Network
import CryptoKit

/* ============================================================
   真人语音/视频通话（App ↔ App、App ↔ 网页版都能通）

   信令和网页版走同一条 WebSocket、同一套格式：
     打电话:  {type:'call', action:'invite', callId, toUserId, media, sdp}
     对方响铃:{action:'ringing'} / 对方来电: {action:'incoming', callId, media, peerId, peerName, sdp}
     接听:    {action:'accept', callId, sdp}
     接通:    {action:'accepted'} / 对端 SDP: {action:'sdp', sdp}
     打洞:    {action:'ice', callId, candidate}   两端互发
     挂断:    {action:'hangup'|'cancel'|'reject'}

   媒体走 WebRTC 点对点（P2P），服务器只转发信令，不经过音频视频。
   同一局域网可以直接连（host 候选），跨网络需要 STUN/TURN —— 后台
   「🎨 登录页/语音通话」里配了 iceServers 就用配的，没配就用公共 STUN。
   ============================================================ */

/// 群语音通话里的一个人（画头像墙用）
struct GroupCallMember: Identifiable, Equatable {
    var userId: String
    var name: String
    var avatar: String
    var muted: Bool
    var id: String { userId }
}

/// 通话里能选的一个音频出口（微信那个「听筒 / 扬声器 / 蓝牙」菜单里的一行）
/// 通话自检的实时快照（2026-10-14 用户要求"装一个检测在手机里"）：
/// 通话页点「自检」就能看到这些值 —— 走哪条通道、TURN 有没有用上、麦克风权限、
/// 收发字节/丢包/抖动、TRTC 有没有报错。看一眼就知道"没声音"卡在哪一步。
struct CallLiveDiag: Equatable {
    var channel = "-"            // TRTC / 服务器转发 / WebRTC（P2P 或 relay）
    var ice = "-"                // new / checking / connected / failed …
    var relayUsed = false        // 选中候选对里有没有 relay（= 真的用上了我们的 TURN）
    var audioEnabled = false     // WebRTC 音频轨道是否启用
    var micPermission = "-"      // granted / denied / undetermined
    var audioSession = "-"       // category/mode（期望 playAndRecord/voiceChat）
    var audioRoute = "-"         // 当前输出设备
    var bytesSent = 0
    var bytesReceived = 0
    var packetsLost = 0
    var jitter = 0.0
    var trtcPeerInRoom = false
    var wsOK = false
    var updatedAt = ""
}

struct CallAudioRoute: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String          // receiver / speaker / bluetooth / headset

    var icon: String {
        switch kind {
        case "speaker": return "speaker.wave.2.fill"
        case "bluetooth": return "wave.3.right.circle"
        case "headset": return "headphones"
        default: return "phone.fill"
        }
    }
}

/// 和服务端 groupRoomId() 完全一致：同一个群固定同一个房间号。
/// 客户端提前算出来，点发起群通话后不必等 group-ready 才能邀请成员。
private func groupCallRoomID(_ chatId: String) -> String {
    let bytes = Insecure.SHA1.hash(data: Data(chatId.utf8))
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    return "gr_" + String(hex.prefix(12))
}

/* ⚠ @MainActor 必须紧贴在 CallCenter 头上 —— 他们的半成品把它写在了新加的
   struct 上面，等于 CallCenter 整个丢了 MainActor 标注，于是
   「main actor-isolated property ... from a nonisolated context」一口气报了三十多条。
   2026-10-12 修。 */
@MainActor
final class CallCenter: NSObject, ObservableObject {
    static let shared = CallCenter()

    enum Phase: Equatable {
        case idle, outgoing, incoming, connecting, active
        var isBusy: Bool { self != .idle }
    }

    @Published private(set) var phase: Phase = .idle {
        didSet {
            /* 自检跟着通话走：接通开始每秒采集，回到 idle 就停（2026-10-14） */
            if phase != oldValue {
                if phase == .active { startLiveDiag() }
                else if phase == .idle { stopLiveDiag() }
            }
        }
    }
    @Published private(set) var peerName = ""
    @Published private(set) var peerAvatar = ""
    @Published private(set) var isVideo = false
    @Published private(set) var muted = false
    @Published private(set) var cameraOff = false
    /// 扬声器（扬声器已开 / 已关，参考图底下那排有这一项）
    @Published private(set) var speakerOn = false
    /// 贴耳切听筒：手机贴到耳朵上（距离感应）→ 走听筒；拿开 → 回扬声器
    @Published private(set) var proximityNear = false
    /// 视频通话的「模糊背景」开着没有
    @Published private(set) var blurBackground = false
    @Published private(set) var seconds = 0
    @Published private(set) var tip = ""
    /// 接通 / 挂断弹的对话框（用户要的就是这个形式：居中一个框 + 「确定」）。
    /// 颜色/圆角跟聊天页那行时间用的是同一套后台配置，所以长得和聊天的框框一样。
    struct Dialog: Equatable {
        var title = ""
        var detail = ""
        var okText = "确定"
        var auto: Double = 0          // > 0 表示过这么多秒自动关掉（接通那种不用手动点）
    }
    @Published var dialog: Dialog? = nil
    private var dialogTask: Task<Void, Never>?
    /// 距离感应的观察者（语音通话期间才有）
    private var proximityObserver: NSObjectProtocol?
    /// 打不通时那 8 秒的定时器（见 failLater）
    private var failTask: Task<Void, Never>?
    /// 连不上时的诊断记录（ICE 状态、候选数量…），通话结束时一起报给服务器
    private var diag: [String] = []
    /* 实时自检（2026-10-14）：通话页「自检」面板读这个；通话激活时每秒刷新一次 */
    @Published private(set) var diagLive = CallLiveDiag()
    private var diagLiveTimer: Timer?

    func startLiveDiag() {
        diagLiveTimer?.invalidate()
        diagLiveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshLiveDiag()
        }
        refreshLiveDiag()
    }
    func stopLiveDiag() {
        diagLiveTimer?.invalidate()
        diagLiveTimer = nil
    }
    /// 取一次实时状态（每一项都是"能不能通话"的直接证据）
    private func refreshLiveDiag() {
        var d = CallLiveDiag()
        d.channel = usingTRTC ? "TRTC（腾讯）" : (serverAudioOn ? "服务器转发" : "WebRTC")
        d.ice = pc.map { String(describing: $0.iceConnectionState) } ?? "-"
        d.audioEnabled = audioTrack?.isEnabled ?? false
        d.trtcPeerInRoom = trtcPeerInRoom
        d.wsOK = Realtime.shared.connected
        let s = AVAudioSession.sharedInstance()
        switch s.recordPermission {
        case .granted: d.micPermission = "granted"
        case .denied: d.micPermission = "denied"
        default: d.micPermission = "undetermined"
        }
        d.audioSession = s.category.rawValue + " / " + s.mode.rawValue
        d.audioRoute = (s.currentRoute.outputs.first?.portType.rawValue) ?? "-"
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
        d.updatedAt = fmt.string(from: Date())
        self.diagLive = d                       // 先给界面一份（统计是异步的，回来再补）
        guard let conn = pc else { return }
        conn.statistics { report in
            var nd = d
            for (_, st) in report.statistics {
                if st.type == "outbound-rtp" {
                    if let v = st.values["bytesSent"] as? NSNumber { nd.bytesSent = v.intValue }
                }
                if st.type == "inbound-rtp" {
                    if let v = st.values["bytesReceived"] as? NSNumber { nd.bytesReceived = v.intValue }
                    if let v = st.values["packetsLost"] as? NSNumber { nd.packetsLost = v.intValue }
                    if let v = st.values["jitter"] as? NSNumber { nd.jitter = v.doubleValue }
                }
                if st.type == "candidate-pair", (st.values["nominated"] as? NSNumber)?.boolValue == true {
                    if let lid = st.values["localCandidateId"] as? String,
                       let lc = report.statistics[lid],
                       let ct = lc.values["candidateType"] as? String, ct == "relay" {
                        nd.relayUsed = true
                    }
                }
            }
            DispatchQueue.main.async { self.diagLive = nd }
            /* 每 5 秒往「通话结束上报给服务器」的那份记录里塞一条：
               用户打完一通，我们在服务端就能看到「走的哪条通道 / TURN 有没有用上 /
               麦克风权限 / 收发字节 / 丢包」全过程（2026-10-14 加，配合"手机里的检测"） */
            if self.diag.count < 20, Int(Date().timeIntervalSince1970) % 5 == 0 {
                self.diag.append("[live] " + nd.channel
                    + " ice=" + nd.ice + " relay=" + (nd.relayUsed ? "Y" : "N")
                    + " mic=" + nd.micPermission + " route=" + nd.audioRoute
                    + " audioOn=" + (nd.audioEnabled ? "Y" : "N")
                    + " tx=" + String(nd.bytesSent) + " rx=" + String(nd.bytesReceived)
                    + " lost=" + String(nd.packetsLost) + " jitter=" + String(format: "%.3f", nd.jitter))
            }
        }
    }
    /// 语音是否正在走「服务器转发」这条路
    private var serverAudioOn = false
    /// 媒体是不是**已经**交给腾讯云 TRTC 了（界面据此换成 TRTC 画面）。
    /// 注意：TRTC 自己进房成功还不算，要等「对端也在这个房间里」才切 ——
    /// 否则对面若是旧版本（没有 TRTC），两边会各自说给不同的通道，结果谁都听不到。
    @Published private(set) var usingTRTC = false
    /// TRTC 已进房（还没切媒体）
    private var trtcJoined = false
    /// TRTC 的远端画面 / 本地小窗（界面直接用）
    var trtcRemoteView: UIView? { TRTCBridge.shared.remoteView }
    var trtcLocalView: UIView? { TRTCBridge.shared.localView }
    /// TRTC 进房后对端在不在
    var trtcPeerInRoom: Bool { TRTCBridge.shared.peerInRoom }

    func dismissDialog() {
        dialogTask?.cancel()
        dialogTask = nil
        dialog = nil
    }

    /// 弹一个对话框：title 必给，detail 可以空，auto > 0 就是自动关掉
    func showDialog(_ title: String, detail: String = "", auto: Double = 0) {
        guard !title.isEmpty else { return }
        dialogTask?.cancel()
        dialog = Dialog(title: title, detail: detail, auto: auto)
        guard auto > 0 else { return }
        dialogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(auto * 1_000_000_000))
            guard let self = self, !Task.isCancelled else { return }
            self.dialog = nil
        }
    }
    /// 给界面渲染用的远端 / 本地画面
    @Published private(set) var remoteVideo: RTCVideoTrack?
    @Published private(set) var localVideo: RTCVideoTrack?
    /// 出错提示（界面弹一下就行）
    @Published var errorText: String?
    /// 最小化：通话照旧，界面缩成顶部一条（微信左上那个画中画按钮）
    @Published var minimized = false
    /// 有没有拿到「中继(relay)」候选：外网通话能不能兜底全看它。界面会显示出来，方便排查。
    @Published var relayOK = false
    /// 麦克风没权限 / 没起来：通话页上直接挂一条「对方听不到你」的提示 + 「去开启」。
    /// 以前这种情况界面一切正常、对面一个字听不到，用户完全不知道问题出在哪。
    @Published private(set) var micBlocked = false
    /* 对方那边的状态（和微信一样画出来）：
       「对方已静音」/「对方已关闭摄像头」—— 以前对面关了摄像头，你这边只有一片黑，
       完全不知道是他关了还是网络断了（用户要求补上）。 */
    @Published private(set) var peerMuted = false
    @Published private(set) var peerCameraOff = false
    /// 网络不稳定（WebRTC 掉到 disconnected）：通话页会写一行「网络不太稳定，正在重连…」
    @Published private(set) var weakNet = false
    /* ================= 群语音通话（多人，2026-10-12） =================
       一个群聊一个房间，语音走服务端混音（见服务器 group-* 那几个 action）；
       客户端还是"推一路、收一路"，音频管线复用 CallAudioPipe。 */
    @Published private(set) var isGroupCall = false
    @Published private(set) var roomId = ""
    @Published private(set) var groupChatId = ""
    @Published private(set) var groupTitle = ""
    @Published private(set) var roster: [GroupCallMember] = []

    private var factory: RTCPeerConnectionFactory?
    private var pc: RTCPeerConnection?
    /// 这一通的 id（CallView 里 .task(id:) 要读它，所以不能是 private）
    private(set) var callId = ""
    /// 当前通话的对方（聊天页靠它判断"这通电话是不是跟这个人打的"）
    private(set) var peerId = ""
    private var iAmCaller = false
    private var remoteOfferSDP: String?
    private var pendingIce: [RTCIceCandidate] = []
    /// 等服务器回答「两端是不是同一个网络」的等待者
    private var netWaiters: [String: CheckedContinuation<Bool, Never>] = [:]
    /// 「模糊背景」那层采集代理（1 对 1 视频走 WebRTC 那条路，要一直持有）
    private var blurDelegate: BlurCapturer?

    /// 问服务器：我和对端是不是同一个网络？
    /// 同一个 → 直连（快、不占带宽）；不同 → 强制走中继（4G↔宽带这种直连经常只通一半）
    func askSameNetwork(peerUserId: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            netWaiters[peerUserId] = cont
            Realtime.shared.sendJSON(["type": "call", "action": "net", "peerId": peerUserId])
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if let c = netWaiters.removeValue(forKey: peerUserId) {
                    c.resume(returning: false)      // 问不到就按「不同网络」处理：走中继最稳
                }
            }
        }
    }
    private var audioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?
    private var videoSource: RTCVideoSource?
    private var capturer: RTCCameraVideoCapturer?
    private var ticker: Timer?
    /// 通话中「采集端连续几秒没起来」的计数（见 checkMicAlive）
    private var micDownTicks = 0
    /// 拨出去没人接的兜底计时（服务端 45 秒也会结束，这里是客户端保险，别让界面卡在"呼叫中"）
    private var ringTimer: Timer?
    /// 「正在接通」时的 12 秒观察（连不上就给提示）
    private var connectTimer: Timer?
    private var sub: AnyCancellable?
    /* 打洞 / 中转服务器。默认这套是国内能连上的 STUN + 一个公共 TURN：
       同一个 Wi-Fi 里其实用不到它们，但**跨网络**（4G/别人家宽带）必须靠 TURN 中转，
       不然对称 NAT 下两边根本连不上。后台「语音通话」里填了 iceServers 就用后台的。 */
    private var iceServers: [RTCIceServer] = [
        RTCIceServer(urlStrings: ["stun:stun.miwifi.com:3478", "stun:stun.cloudflare.com:3478"]),
        RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]),
        RTCIceServer(urlStrings: ["turn:openrelay.metered.ca:80", "turn:openrelay.metered.ca:443"],
                     username: "openrelayproject", credential: "openrelayproject")
    ]

    private override init() {
        super.init()
        // 服务器一推 call 事件就交给 handle
        sub = Realtime.shared.$event
            .receive(on: RunLoop.main)
            .sink { [weak self] ev in
                /* ready 也要放进来：重连时靠它校对"我还该不该显示通话页" */
                guard ev.type == "call" || ev.type == "call-error" || ev.type == "ready" else { return }
                self?.handle(ev)
            }
        Task { await loadIce() }
        startPathMonitor()
        /* 去系统设置里把麦克风打开、再回到 App：自动把采集抢回来（用户不用重拨） */
        _ = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.micBlocked, self.phase != .idle else { return }
                if await Permission.ask(.audio) {
                    self.micBlocked = false
                    self.errorText = nil
                    CallAudioPipe.shared.repairAudioNow()
                    self.note("麦克风权限已开，重新抢麦")
                }
            }
        }
    }

    /// 麦克风没开时那条提示上的「去开启」：直接把用户送到系统设置里本 App 那一页
    func openMicSettings() {
        guard let u = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(u)
    }

    /// 已经开了权限但采集没起来时，让用户点一下立刻重试（不用重拨）
    func retryMic() {
        micBlocked = false
        errorText = nil
        CallAudioPipe.shared.repairAudioNow()
    }

    /* ---------------------------------------------------------- 对外动作 */

    /// 打出去（peer 是一对一会话里的对方）
    func start(peerId: String, name: String, avatar: String, video: Bool) {
        /* 状态要是卡住了（比如上一通结束后有异步回调把「通话中」又设回来），
           先自愈一次再判断 —— 不然用户点拨打只会看到「正在通话中」，打不出去。 */
        resetIfStale()
        guard phase == .idle else { errorText = "正在通话中"; return }
        guard !peerId.isEmpty else { errorText = "找不到对方账号"; return }
        dismissDialog()                 // 上一通留下的对话框别压在新通话上面
        minimized = false               // 上一通要是挂起过（小浮窗），新的一通必须整页打开
        self.peerId = peerId
        peerName = name
        peerAvatar = avatar
        isVideo = video
        iAmCaller = true
        relayOK = false                      // 新的一通电话：中继状态重新算
        muted = false
        micBlocked = false
        cameraOff = false
        seconds = 0
        tip = video ? "正在等待对方接受邀请…" : "正在呼叫…"
        callId = "call" + String(Int(Date().timeIntervalSince1970 * 1000)) + String(UUID().uuidString.prefix(4))
        phase = .outgoing
        startRingTimeout()
        Ringtone.shared.startRingback()        // 等对方接的时候放回铃音（嘟——）
        Task { await beginMedia() }
        /* ⚠ 语音**不再进 TRTC 房间**（2026-09-25 线上实测后改回来）：
           TRTC 以 role=anchor 进房时会自己开一路本地音频采集，把我们的转发通道
           挤成空壳（采集=ok 却一个 buffer 都不回调），我们抢麦失败 → 重试时
           AVAudioSession.setActive(false) 顺手把播放引擎掐停 → 「两边都在发帧、
           服务器也都在转发，但谁都听不见」（call-trace.log 里
           「采集=失败 原因:（空）」紧跟「采集=ok」就是这一串）。
           语音现在只走服务器转发这一条路（它本身不依赖 TURN/直连，运营商也挡不住），
           视频照旧走腾讯云。 */
        if video { Task { await startTRTCIfPossible() } }
    }

    /// 接听（来电界面点绿键）
    /// 接听。asAudio = true 就是「视频来电用语音接听」（微信视频来电也有这一档）
    func accept(asAudio: Bool = false) {
        guard phase == .incoming else { return }
        if asAudio, isVideo {
            isVideo = false
            sendCall(["action": "media", "media": "audio"])   // 协议是 media（服务器没有 switch）
        }
        Ringtone.shared.stop()
        relayOK = false                      // 接起来：中继状态重新算
        /* 上一通要是静音着挂的，这里必须复位 —— 不然这一通采到了也一帧都不发，
           表现就是「对面听不见我」，而且用户完全看不出原因。 */
        muted = false
        micBlocked = false
        phase = .connecting
        tip = "正在接通…"
        Task { await beginMedia() }
        if isVideo { Task { await startTRTCIfPossible() } }
        startConnectWatch()
        /* 注意：这里**不能**直接开始采集。
           麦克风权限是在 beginMedia() 里现申请的（第一次会弹窗），
           以前这一行紧跟在 Task 后面立刻执行 —— 权限还没到手就开始采集，
           结果是「拿不到麦克风输入」，整通电话对面一个字都听不到（假通）。
           现在由 beginMedia() 在拿到权限之后再启动转发通道。 */
    }

    /// 拒接
    func reject() {
        guard !callId.isEmpty else { return }
        sendCall(["action": "reject"])
        finish(tip: "已拒绝")
    }

    /// 拒接并回一句（2026-10-13 用户要求，对齐微信「拒绝并回复」）：
    /// 先往这个会话里发一条文字，再正常拒接 —— 对方那边会直接看到这句话。
    func reject(withReply text: String) {
        let say = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callId.isEmpty else { return }
        /* 说明一句走服务器的拒接通道（服务端知道这两个人是谁，直接往他们的单聊里插一条
           —— 客户端这边不用自己去猜会话 id） */
        if say.isEmpty { sendCall(["action": "reject"]) }
        else { sendCall(["action": "reject", "text": say]) }
        finish(tip: "已拒绝")
    }

    /* ---------------- ② 语音中切视频 / ③ 谁在说话 / ④ 拉人入会（2026-10-13 对标微信） ---------------- */

    /// ③ 群里每个人的音量（id → 0…1），界面用来给「正在说话的人」画光圈
    @Published var speakerLevels: [String: Double] = [:]
    /// 自己刚才报出去的音量（防重复上报）
    private var lastLevelSent: Double = -1
    private var levelTask: Task<Void, Never>?

    /// ② 语音通话中「切到视频」（对齐微信）：把 media 报成 video，两端各自把视频打开。
    /// 视频走腾讯云 TRTC（我们本来就接了它），比临时给 WebRTC 加一路轨稳。
    func upgradeToVideo() {
        guard phase == .active, !isVideo, !isGroupCall else { return }
        isVideo = true
        sendCall(["action": "media", "media": "video"])
        note("切到视频通话")
        Task { await startTRTCIfPossible() }
    }

    /// ④ 通话中把群成员拉进**同一个**通话（不再只是发一条邀请消息）
    func inviteToCall(_ userId: String) {
        guard !userId.isEmpty else { return }
        /* 2026-10-17：以前这里 roomId 为空就**静默 return**（点了没反应、也没有任何提示）。
           现在给一句人话，免得看着像"按钮坏了"。 */
        guard !roomId.isEmpty else {
            showDialog("这个通话还没建好", detail: "再等几秒，等通话连上以后再邀请（房间号还没回来）。")
            return
        }
        /* 微信的规矩：一个通话最多 9 方（服务器那边也挡了一道，这里先说清楚，
           别让人点了没反应） */
        guard roster.count < 9 else {
            showDialog("通话人数已满", detail: "一个通话最多 9 个人。")
            return
        }
        sendCall(["action": "group-invite", "roomId": roomId, "toUserId": userId])
        note("邀请 " + userId + " 加入通话")
    }

    /// 这个通话是不是已经满 9 个人了（UI 用来提示/置灰）
    var groupCallFull: Bool { isGroupCall && roster.count >= 9 }

    /// ③ 每隔 300ms 把自己这边的音量报给服务器（只在群通话里用得上）
    private func startLevelReporting() {
        levelTask?.cancel()
        levelTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { break }
                guard phase.isBusy, isGroupCall else { continue }
                let lv = Double(CallAudioPipe.shared.lastLevel)
                if abs(lv - lastLevelSent) < 0.02 { continue }   // 没变就不发，省流量
                lastLevelSent = lv
                sendCall(["action": "level", "level": max(0, min(1, lv))])
            }
        }
    }

    /// ③ 别人报上来的音量（服务器每 250ms 汇总一次广播过来）
    private func applyLevels(_ ev: PushEvent) {
        guard isGroupCall else { return }
        speakerLevels = ev.callLevels
    }

    /// 挂断 / 取消
    func hangup() {
        guard phase.isBusy else { return }
        if isGroupCall { leaveGroupCall(); return }
        failTask?.cancel()
        failTask = nil
        let started = (phase == .active)
        if !callId.isEmpty {
            sendCall(["action": started ? "hangup" : (iAmCaller ? "cancel" : "reject")])
        }
        finish(tip: started ? "通话结束" : "已取消")
    }

    func toggleMute() {
        muted.toggle()
        audioTrack?.isEnabled = !muted
        if usingTRTC { TRTCBridge.shared.setMuted(muted) }
        /* 告诉对方「我静音了」—— 他那边会画一行「对方已静音」（微信就是这样） */
        sendCall(["action": "state", "muted": muted, "camOff": cameraOff])
    }

    func toggleCamera() {
        guard isVideo else { return }
        cameraOff.toggle()
        localVideoTrack?.isEnabled = !cameraOff
        if usingTRTC { TRTCBridge.shared.setCameraOff(cameraOff) }
        sendCall(["action": "state", "muted": muted, "camOff": cameraOff])
    }

    /// 通话中切「语音 ↔ 视频」（不挂断，微信有这个）：
    /// 先通知对方，再在本地把视频轨道开/关。
    func switchVideo() {
        guard phase == .active || phase == .connecting || phase == .outgoing else { return }
        isVideo.toggle()
        /* ⚠ 2026-10-13 修「语音→视频升级不生效」：以前发的是 `action:'switch'`，
           而**服务器根本没有 switch 这个动作**（它只认 media）—— 对面永远收不到，
           所以切了跟没切一样。现在按服务器的协议发 media。 */
        sendCall(["action": "media", "media": isVideo ? "video" : "audio"])
        if isVideo {
            stopProximity()                 // 切视频了：不再贴耳切听筒
            Task {
                await beginMedia()
                await startTRTCIfPossible()
            }
            tip = "正在切换为视频通话…"
        } else {
            localVideoTrack?.isEnabled = false
            if usingTRTC { TRTCBridge.shared.setCameraOff(true) }
            tip = "已切换为语音通话"
        }
    }

    /// 扬声器开关：语音通话默认走听筒（关），视频通话默认开
    func toggleSpeaker() {
        speakerOn.toggle()
        applySpeaker()
        if usingTRTC { TRTCBridge.shared.setSpeaker(speakerOn) }
    }

    func minimize() { minimized = true }
    func restore() { minimized = false }

    /* ==================== 群语音通话（多人） ==================== */

    /// 在群里发起群语音（群聊的「聊天信息」或「＋」里点进来）
    func startGroupCall(chatId: String, title: String, video: Bool = false) {
        /* 2026-10-17：加一条"点了就上报"（排查"点了没反应、服务端什么都没有"） */
        Task { await API.shared.callDiag("群通话点了 chat=\(chatId) video=\(video) phase=\(phase)") }
        /* 上一通的状态没退干净时先自愈一次，再判断 —— 不然用户点下去只有一句"你正在通话中" */
        if phase != .idle { resetIfStale() }
        guard phase == .idle else {
            errorText = "你正在通话中"
            Task { await API.shared.callDiag("群通话被挡：phase=\(phase)") }
            return
        }
        isGroupCall = true
        isVideo = video
        groupChatId = chatId
        groupTitle = title
        /* 不等服务器回 group-ready：本地先算出同一个群房间号。
           这样发起后的第一秒就能点「邀请」，服务端按 WebSocket 顺序先建群房、再发邀请。 */
        roomId = groupCallRoomID(chatId)
        roster = []
        peerName = title
        peerAvatar = ""
        muted = false
        cameraOff = false
        seconds = 0
        tip = "正在邀请群成员…"
        phase = .outgoing
        iAmCaller = true
        /* 群语音走服务端混音；**群视频**走腾讯云 TRTC（多人画面只有它这条路），
           所以视频这一档不启服务端转发，等进房回执到了由 joinGroupTRTC() 接管。 */
        if !video { startGroupAudio() }         // 先把自己的声音通道起起来
        Realtime.shared.sendJSON(["type": "call", "action": "group-start", "chatId": chatId,
                                  "media": video ? "video" : "audio"])
        startConnectWatch()
    }

    /// 别人拉我进群语音：接听
    func acceptGroupCall() {
        guard phase == .incoming || phase == .outgoing else { return }
        Ringtone.shared.stop()
        muted = false
        micBlocked = false
        tip = "正在接通…"
        phase = .connecting
        iAmCaller = false
        if isVideo {
            /* 群视频：自己的采集交给 TRTC，别启服务端那路（两个引擎抢麦会都没声） */
        } else {
            startGroupAudio()
        }
        Realtime.shared.sendJSON(["type": "call", "action": "group-join",
                                  "roomId": roomId, "media": isVideo ? "video" : "audio"])
        if isVideo { Task { await joinGroupTRTC() } }
        startConnectWatch()
    }

    /// 群视频：进 TRTC 房间（每人一路画面，TRTC 自动订阅；画面由 CallView 的宫格去取）
    private func joinGroupTRTC() async {
        guard isGroupCall, isVideo, !roomId.isEmpty, !trtcJoined, !usingTRTC else { return }
        let bridge = TRTCBridge.shared
        bridge.onJoined = { [weak self] ok in
            guard let self = self, ok else { return }
            guard self.phase != .idle else { return }
            self.trtcJoined = true
            self.usingTRTC = true
            /* ⚠ 老规矩：进房之后才 activate()（TRTC 一进房就抢麦会把别的采集挤空） */
            bridge.activate()
            self.note("群视频：TRTC 已进房并开始采集")
        }
        if await bridge.start(roomSeed: roomId, video: true) {
            note("群视频：正在进 TRTC 房间")
        } else {
            note("群视频：TRTC 进不去，退回语音转发")
            if !serverAudioOn { startGroupAudio() }
        }
    }

    /// 退出群语音（挂断）
    func leaveGroupCall() {
        if !roomId.isEmpty {
            Realtime.shared.sendJSON(["type": "call", "action": "group-leave", "roomId": roomId])
        }
        /* 群视频：把腾讯云那路也退了 + 收掉每个人的画面 */
        if isVideo || TRTCBridge.shared.joined {
            TRTCBridge.shared.stopMeetingViews()
            TRTCBridge.shared.stop()
        }
        CallAudioPipe.shared.onFrame = nil
        CallAudioPipe.shared.stop()
        serverAudioOn = false
        isGroupCall = false
        roomId = ""
        groupChatId = ""
        roster = []
        finish(tip: "通话结束")
    }

    /// 群语音的音频通道：一帧 40ms，走服务端混音
    private func startGroupAudio() {
        guard !serverAudioOn else { return }
        serverAudioOn = true
        audioTrack?.isEnabled = false              // 语音不走 WebRTC，别叠一份
        CallAudioPipe.shared.onFrame = { [weak self] data in
            guard let self = self, !self.muted, !self.roomId.isEmpty else { return }
            Realtime.shared.sendJSON(["type": "call", "action": "group-audio",
                                      "roomId": self.roomId,
                                      "data": data.base64EncodedString()])
        }
        CallAudioPipe.shared.start()
    }

    /// 邀请好友加入通话：给对方发一条邀请消息（点它就能回拨过来）。
    /// 提示：多人同时在一个通话里需要服务器支持多路，这块还没做，所以现在是把人叫进来。
    func invite(userId: String, name: String) async -> String {
        do {
            let chat = try await API.shared.directChat(userId: userId)
            _ = try await API.shared.send(chatId: chat.id, kind: "text",
                                          content: "邀请你加入语音通话，点这条消息回拨给我")
            return "已邀请 \(name)"
        } catch {
            return (error as? APIError)?.errorDescription ?? "邀请失败"
        }
    }

    private func applySpeaker() {
        let s = AVAudioSession.sharedInstance()
        /* 贴耳切听筒期间以「耳朵」为准：这时候就算扬声器开着也走听筒，
           不然贴着耳朵还在外放（微信也是这个行为） */
        try? s.overrideOutputAudioPort((speakerOn && !proximityNear) ? .speaker : .none)
    }

    /* ============================================================
       通话的音频出口（对齐微信那套）+ 贴耳自动切听筒
       ============================================================ */

    /// 现在能选哪些音频出口：iPhone（听筒）/ 蓝牙耳机 / 有线耳机 / 扬声器
    func audioDevices() -> [CallAudioRoute] {
        let s = AVAudioSession.sharedInstance()
        var list: [CallAudioRoute] = [
            CallAudioRoute(id: "receiver", name: "iPhone", kind: "receiver")
        ]
        /* 蓝牙 / 有线耳机：系统的输入口里就带着它们（没接就不列） */
        for p in (s.availableInputs ?? []) {
            switch p.portType {
            case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP:
                list.append(CallAudioRoute(id: p.uid, name: p.portName, kind: "bluetooth"))
            case .headsetMic, .headphones:
                list.append(CallAudioRoute(id: p.uid, name: p.portName, kind: "headset"))
            default:
                break
            }
        }
        list.append(CallAudioRoute(id: "speaker", name: "扬声器", kind: "speaker"))
        return list
    }

    /// 当前实际在用的出口（用来在菜单里打钩）
    var currentAudioDeviceName: String {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outs.contains(where: { $0.portType == .builtInSpeaker }) { return "扬声器" }
        if let b = outs.first(where: { $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
            || $0.portType == .bluetoothA2DP }) { return b.portName }
        if let h = outs.first(where: { $0.portType == .headphones || $0.portType == .headsetMic }) {
            return h.portName
        }
        return "iPhone"
    }

    /// 选一个音频出口（微信那个「听筒 / 扬声器 / 蓝牙」菜单点了之后走这里）
    func selectAudioDevice(_ r: CallAudioRoute) {
        let s = AVAudioSession.sharedInstance()
        switch r.kind {
        case "speaker":
            speakerOn = true
            try? s.overrideOutputAudioPort(.speaker)
            if usingTRTC { TRTCBridge.shared.setSpeaker(true) }
        case "receiver":
            speakerOn = false
            try? s.overrideOutputAudioPort(.none)
            if usingTRTC { TRTCBridge.shared.setSpeaker(false) }
        default:
            if let p = (s.availableInputs ?? []).first(where: { $0.uid == r.id }) {
                try? s.setPreferredInput(p)
                speakerOn = false
                try? s.overrideOutputAudioPort(.none)
                if usingTRTC { TRTCBridge.shared.setSpeaker(false) }
            }
        }
    }

    /// 语音通话时开「贴耳切听筒」：手机贴到耳朵上切成听筒（省电、也不吵到旁边人），
    /// 拿开又按扬声器开关的状态回去。视频通话**不开** —— 手机举在眼前，
    /// 一贴近就切听筒反而别扭（微信也是只对语音通话做这个）。
    func startProximity() {
        guard !isVideo else { return }
        guard proximityObserver == nil else { return }
        UIDevice.current.isProximityMonitoringEnabled = true
        proximityObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyProximity() }
        }
    }

    func stopProximity() {
        if let ob = proximityObserver {
            NotificationCenter.default.removeObserver(ob)
            proximityObserver = nil
        }
        UIDevice.current.isProximityMonitoringEnabled = false
        proximityNear = false
    }

    private func applyProximity() {
        guard phase.isBusy, !isVideo else { return }
        proximityNear = UIDevice.current.proximityState
        applySpeaker()
        if usingTRTC { TRTCBridge.shared.setSpeaker(speakerOn && !proximityNear) }
    }

    /* ---------------- 视频通话：模糊背景（对齐微信那一档） ---------------- */

    /// 开 / 关「模糊背景」：只对视频通话有意义。
    /// 画面处理在 VideoBlur 里（人像分割 + 背景高斯模糊），
    /// 任何一帧处理失败都直接放原帧过去 —— 这个功能绝不能把通话弄坏。
    func setBlurBackground(_ on: Bool) {
        VideoBlur.shared.enabled = on
        blurBackground = on
        TRTCBridge.shared.setBackgroundBlur(on)
    }

    func toggleBlurBackground() {
        setBlurBackground(!blurBackground)
    }

    /// 前后摄像头切换（视频通话中）
    func flipCamera() {
        if usingTRTC { TRTCBridge.shared.flipCamera(); return }
        guard isVideo, let capturer = capturer else { return }
        let front = capturer.captureSession.isRunning
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let dev = devices.first(where: { $0.position == (front ? .back : .front) }) ?? devices.first else { return }
        guard let fmt = bestFormat(for: dev) else { return }
        capturer.startCapture(with: dev, format: fmt, fps: 30)
    }

    /* ---------------------------------------------------------- 信令 */

    private func sendCall(_ body: [String: Any]) {
        var msg: [String: Any] = ["type": "call", "callId": callId]
        body.forEach { msg[$0.key] = $0.value }
        Realtime.shared.sendJSON(msg)
    }

    /// 语音通话：开始走「服务器转发」这条路（不用等 WebRTC，运营商挡不住）
    private func startServerAudioIfVoice() {
        guard !isVideo else { return }
        guard !serverAudioOn else { return }
        serverAudioOn = true
        audioTrack?.isEnabled = false          // 别让 WebRTC 的音频再叠一份
        CallAudioPipe.shared.onFrame = { [weak self] data in
            guard let self = self, !self.muted else { return }
            self.sendCall(["action": "audio", "data": data.base64EncodedString()])
        }
        CallAudioPipe.shared.start()
        /* 这条路已经开始传声音了：界面直接进入「通话中」并开始计时（不用等 ICE） */
        if phase != .active {
            Ringtone.shared.stop()
            phase = .active
            tip = "通话中"
            ringTimer?.invalidate()
            ringTimer = nil
            startTimer()
        }
        /* 放在设完 tip 之后：麦克风没起来时要把「通话中」改写成提醒，不能被覆盖掉 */
        reportMicState(prefix: "App 语音走服务器转发")
    }

    /// 采集起来没有：起来了就一切照旧；没起来就在界面上直说（别再「假通」了）
    private func reportMicState(prefix: String) {
        let p = CallAudioPipe.shared
        /* 等采集通道「真正起来/彻底失败」再报（异步回调），别在 start() 刚返回就下结论 ——
           之前日志里那种「采集=失败 原因:（空）」就是打点太早的误报。 */
        p.onStateChange = { [weak self] ok in
            guard let self = self else { return }
            p.onStateChange = nil
            self.micReported(ok, prefix: prefix)
        }
        /* 兜底：采集最多会抢 6 次（约 4~5 秒），这里等 7 秒再自己看一眼，
           别在重试还没结束时就报「失败」。 */
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [weak self] in
            guard let self = self, p.onStateChange != nil else { return }
            p.onStateChange = nil
            self.micReported(p.isRunning, prefix: prefix)
        }
    }

    private func micReported(_ ok: Bool, prefix: String) {
        let reason = CallAudioPipe.shared.lastError
        Task { await API.shared.callDiag(prefix + " 采集=" + (ok ? "ok" : "失败")
            + (ok ? "" : " 原因: " + reason)) }
        if ok {
            micBlocked = false
            note("语音走服务器转发 ✓")
            /* 6 秒后再报一次「播放端」的状态：万一用户还是说没声音，
               call-trace.log 里一眼就能分清是「一帧都没收到」还是
               「收到了但排不进播放器」（以前日志只有采集那一半，查不出来）。 */
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self = self, !self.callId.isEmpty, !self.isVideo else { return }
                let p = CallAudioPipe.shared
                guard self.serverAudioOn || p.framesIn > 0 else { return }
                await API.shared.callDiag("语音 6 秒自检 " + p.playDiag)
            }
        } else {
            /* 采集没起来 = 对面听不到我：页面上必须挂提示，别让用户以为通话是好的 */
            micBlocked = true
            note("麦克风没起来")
            tip = reason.contains("权限") ? "麦克风权限没开：设置 → 本 App → 麦克风"
                                         : "麦克风没起来，对方可能听不到你说话"
        }
    }

    private func handle(_ ev: PushEvent) {
        /* 重连（从后台回来 / 切网）时校对一次：服务器上已经没有我这一通电话了，
           就把本地的通话页收掉 —— 不然会出现「对方早挂断了、我这边还显示通话中」，
           而且这通也不会留下通话时长记录。 */
        if ev.type == "ready" {
            if phase != .idle, ev.callActive == false { finish(tip: "通话已结束") }
            return
        }
        if ev.type == "call-error" {
            if !ev.callError.isEmpty { errorText = ev.callError }
            /* 打不通（对方不在线 / 忙线 / 不能打）：先留在通话页上把原因显示几秒，
               再自动挂断。以前是一有 error 就 finish，用户只看到通话页一闪 ——
               用户要求「显示时间长一点再自动挂断」。 */
            if ev.callId == callId { failLater(ev.callError) }
            return
        }
        let action = ev.callAction
        switch action {
        case "net":
            if let c = netWaiters.removeValue(forKey: ev.callPeerId) { c.resume(returning: ev.callSameNetwork) }
        case "incoming":
            // 已经在通话里就自动挂掉（和网页版一样，服务器也会挡忙线）
            guard phase == .idle else {
                Realtime.shared.sendJSON(["type": "call", "action": "reject", "callId": ev.callId])
                return
            }
            callId = ev.callId
            peerId = ev.callPeerId
            peerName = ev.callPeerName.isEmpty ? "对方" : ev.callPeerName
            peerAvatar = ev.callPeerAvatar
            isVideo = (ev.callMedia == "video")
            iAmCaller = false
            muted = false
            cameraOff = false
            peerMuted = false                 // 新的一通：对面那些状态先复位
            peerCameraOff = false
            seconds = 0
            remoteOfferSDP = ev.callSDP
            tip = isVideo ? "邀请你视频通话…" : "邀请你语音通话…"
            phase = .incoming
            startRingTimeout()
            /* App 不在前台：发一条本地通知，锁屏/主屏也能看到并能接（方案 2） */
            if UIApplication.shared.applicationState != .active {
                LocalNotify.incomingCall(callId: callId, peerName: peerName, video: isVideo)
            }
            Ringtone.shared.startIncoming()    // 来电铃声响起来（重复放到接/挂）
            UINotification.buzz()          // 震动提醒

        case "ringing":
            guard ev.callId == callId else { return }
            tip = isVideo ? "正在等待对方接受邀请…" : "正在呼叫…"

        /* 对方静音了 / 关了摄像头 —— 画到通话页上（微信就是这两行小字） */
        case "state":
            guard ev.callId == callId else { return }
            peerMuted = ev.callPeerMuted
            peerCameraOff = ev.callPeerCameraOff

        /* 对方在通话中切了「语音 ↔ 视频」 */
        case "switch":
            guard ev.callId == callId else { return }
            if ev.callPeerVideo != isVideo {
                isVideo = ev.callPeerVideo
                tip = isVideo ? "对方切换成了视频通话" : "对方切换成了语音通话"
                if isVideo { Task { await startTRTCIfPossible() } }
            }

        /* 对方切了媒体（服务器 relay 的是 action:'media'）—— 2026-10-13 加：
           以前只认 switch，而服务器根本不会发 switch（它只发 media），
           所以「对方切视频」这边毫无反应（语音→视频升级不生效的第二个原因）。 */
        case "media":
            guard ev.callId == callId else { return }
            let wantVideo = (ev.callMedia == "video")
            if wantVideo != isVideo {
                isVideo = wantVideo
                tip = wantVideo ? "对方切换成了视频通话" : "对方切换成了语音通话"
                if wantVideo {
                    Task {
                        await beginMedia()
                        await startTRTCIfPossible()
                    }
                } else {
                    localVideoTrack?.isEnabled = false
                    if usingTRTC { TRTCBridge.shared.setCameraOff(true) }
                }
            }

        /* ---------------- 群语音通话 ---------------- */

        case "group-incoming":
            /* 群里有人发起了群语音 / 群视频：弹来电页（已经在别的通话里就自动拒） */
            guard phase == .idle else { return }
            isGroupCall = true
            isVideo = ev.callPeerVideo          // 服务端带 video:true 就是群视频
            roomId = ev.callRoomId
            groupChatId = ev.callChatId
            groupTitle = ev.callPeerName.isEmpty ? (isVideo ? "群视频通话" : "群语音通话") : ev.callPeerName
            peerName = groupTitle
            peerAvatar = ev.callPeerAvatar
            roster = ev.callRoster
            muted = false
            cameraOff = false
            seconds = 0
            tip = isVideo ? "邀请你加入群视频通话…" : "邀请你加入群语音通话…"
            phase = .incoming
            startRingTimeout()
            if UIApplication.shared.applicationState != .active {
                LocalNotify.incomingCall(callId: roomId,
                                         peerName: groupTitle + (isVideo ? "（群视频）" : "（群语音）"),
                                         video: isVideo)
            }
            Ringtone.shared.startIncoming()
            UINotification.buzz()

        case "levels":
            /* ③ 「谁在说话」：服务端每 250ms 把整屋音量汇总广播过来 */
            applyLevels(ev)
            return

        case "group-ready":
            /* 我已经在房间里了（服务端回执）：进「通话中」开计时 */
            guard isGroupCall else { return }
            roomId = ev.callRoomId.isEmpty ? roomId : ev.callRoomId
            groupChatId = ev.callChatId.isEmpty ? groupChatId : ev.callChatId
            if !ev.callRoster.isEmpty { roster = ev.callRoster }
            Ringtone.shared.stop()
            ringTimer?.invalidate(); ringTimer = nil
            connectTimer?.invalidate(); connectTimer = nil
            if phase != .active {
                phase = .active
                tip = "通话中"
                startTimer()
            }
            /* 群视频：房间号到手了，进腾讯云房间出画面 */
            if isVideo, !trtcJoined { Task { await joinGroupTRTC() } }

        case "group-joined", "group-left":
            guard isGroupCall, ev.callRoomId == roomId else { return }
            roster = ev.callRoster
            /* ③ 群通话开起来就每 300ms 上报自己的音量（「谁在说话」高亮用） */
            startLevelReporting()
            if action == "group-joined", !ev.callPeerName.isEmpty {
                tip = ev.callPeerName + " 加入了通话"
            }

        case "group-audio":
            guard isGroupCall, let b64 = ev.callAudioData, let d = Data(base64Encoded: b64) else { return }
            CallAudioPipe.shared.play(d)

        case "accepted":
            guard ev.callId == callId else { return }
            Ringtone.shared.stop()
            startConnectWatch()
            if isVideo {
                phase = .connecting
                tip = "正在接通…"
            } else {
                /* 语音：对方接了 —— 通道已经起来就直接进「通话中」开计时；
                   万一拨号那次因权限没批起来失败过，这里再兜一次（start() 幂等）。 */
                if !serverAudioOn { CallAudioPipe.shared.start(); serverAudioOn = true }
                if phase != .active {
                    phase = .active
                    tip = "通话中"
                    ringTimer?.invalidate()
                    ringTimer = nil
                    connectTimer?.invalidate()
                    connectTimer = nil
                    startTimer()
                }
                reportMicState(prefix: "App 语音走服务器转发（对方已接）")
            }

        case "audio":
            /* 服务器转发过来的语音帧：直接丢给播放器（这条路不依赖 TURN/直连，一定通） */
            guard let b64 = ev.callAudioData, let d = Data(base64Encoded: b64) else { return }
            CallAudioPipe.shared.play(d)

        case "sdp":
            guard ev.callId == callId, let sdp = ev.callSDP else { return }
            let desc = RTCSessionDescription(type: .answer, sdp: sdp)
            pc?.setRemoteDescription(desc) { [weak self] err in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let err = err { self.errorText = "接通失败：\(err.localizedDescription)" }
                    self.flushIce()
                }
            }

        case "ice":
            guard ev.callId == callId, let json = ev.callCandidate else { return }
            guard let data = json.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let sdp = (o["candidate"] as? String) ?? ""
            let mid = (o["sdpMid"] as? String) ?? "0"
            let idx = (o["sdpMLineIndex"] as? Int) ?? 0
            let cand = RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(idx), sdpMid: mid)
            if pc?.remoteDescription == nil { pendingIce.append(cand) } else { pc?.add(cand) { _ in } }

        case "end":
            if ev.callId == callId || callId.isEmpty {
                let why: String
                switch ev.callReason {
                case "rejected":     why = "对方已拒绝"
                case "cancel":       why = iAmCaller ? "已取消" : "对方已取消"
                case "timeout":      why = iAmCaller ? "对方无应答" : "未接听"
                case "offline":      why = "对方不在线"
                case "disconnected": why = "对方已断开"
                case "hangup":       why = "通话已结束"
                default:             why = "通话已结束"
                }
                finish(tip: why)
            }

        default:
            break
        }
    }

    /* ---------------------------------------------------------- 媒体 + P2P */

    private func loadIce() async {
        /* 先把自己服务器的内置 TURN 加进去：它永远在（服务器就在跟你说话），
           直连连不上时靠它中转，比任何公网服务都靠得住。 */
        let hostOnly = API.shared.server.split(separator: ":").first.map(String.init) ?? ""
        if !hostOnly.isEmpty {
            /* 自己服务器上的 TURN：TCP 和 UDP 都写上。
               这台云服务器只转发了 TCP 3478（UDP 被服务商挡了），所以 TCP 那条才是能用的。 */
            iceServers.insert(RTCIceServer(urlStrings: ["turn:\(hostOnly):3478?transport=tcp",
                                                       "turn:\(hostOnly):3478?transport=udp"],
                                           username: "chris", credential: "chris1234"), at: 0)
        }
        guard let b = await API.shared.branding(),
              let raw = b.iceServers?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return }
        /* 两种写法都认：
           ① JSON（推荐，能带 TURN 的账号密码）
              [{"urls":"turn:turn.xxx.com:3478","username":"u","credential":"p"}]
           ② 老写法：逗号或换行分隔的一串地址 */
        if let data = raw.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var out: [RTCIceServer] = []
            for it in arr {
                var urls: [String] = []
                if let one = it["urls"] as? String { urls = [one] }
                else if let many = it["urls"] as? [String] { urls = many }
                if urls.isEmpty { continue }
                out.append(RTCIceServer(urlStrings: urls,
                                        username: it["username"] as? String,
                                        credential: it["credential"] as? String))
            }
            if !out.isEmpty { iceServers = out }
            return
        }
        let list = raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !list.isEmpty { iceServers = list.map { RTCIceServer(urlStrings: [$0]) } }
    }

    /* MARK: - 切网自动重连（2026-10-13 稳定性，对标微信）
       微信在 Wi-Fi ↔ 4G 切换、短暂断流时能自己接回来；我们以前只有「网络不太稳定」
       那行提示，3 秒就挂断。现在监听系统网络路径变化：
         · 语音通话：媒体走「服务器转发」那条独立通道 → 换网后重抢麦克风、重接转发
         · 视频通话：直接兜底切到腾讯云 TRTC（它对切网 / 弱网最稳）
       并把「网络切换」写进通话打点，线上能一眼看出是不是切网导致的断线。 */
    private let pathMonitor = NWPathMonitor()
    private var lastPathStatus: NWPath.Status? = nil

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self = self else { return }
                let prev = self.lastPathStatus
                self.lastPathStatus = path.status
                guard prev != nil, prev != path.status else { return }   // 只在真的变了时动手
                guard self.phase == .active else { return }
                self.note("网络切换（" + (path.status == .satisfied ? "已联网" : "断开") + "）→ 自动重连")
                self.weakNet = true
                if self.tip != "通话中" && self.tip != "视频通话中" { self.tip = "网络切换，正在重连…" }
                if self.isVideo {
                    if !self.usingTRTC { await self.startTRTCIfPossible() }
                } else {
                    CallAudioPipe.shared.resetHandOver()
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "chris.call.path"))
    }

    private func makeFactory() -> RTCPeerConnectionFactory {
        if let f = factory { return f }
        let f = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
        factory = f
        return f
    }

    private func beginMedia() async {
        CallAudioPipe.shared.resetHandOver()      // 新的一通：允许本通道重新用麦克风
        let mic = await Permission.ask(.audio)
        /* 麦克风没权限：**不再直接把通话掐掉**（用户会以为"打不通"），
           而是照常接通、在通话页上挂一条明确的「对方听不到你」+「去开启」——
           至少还能听见对方，也知道去哪儿开。打开权限回到前台会自动重新抢麦。 */
        if !mic {
            micBlocked = true
            note("麦克风权限没开")
            Task { await API.shared.callDiag("App 麦克风权限没开（界面已提示）") }
        } else {
            micBlocked = false
        }
        if isVideo {
            let cam = await Permission.ask(.video)
            if !cam { errorText = "没有摄像头权限，去「设置 → CHRIS聊天」里打开"; finish(tip: "没有摄像头权限"); return }
        }
        activateAudioSession()
        speakerOn = isVideo                    // 视频通话默认外放，语音默认听筒
        applySpeaker()
        /* 拨号音在音频会话真正配置好之后再拉起一次：
           之前它先于 beginMedia() 播放，随后 playAndRecord/voiceChat 一切换，
           AVAudioEngine 被系统掐停，用户就完全听不到“嘟——”。 */
        if iAmCaller, phase == .outgoing {
            Ringtone.shared.startRingback()
        }

        /* 语音通话：只听服务器转发，**完全不建 WebRTC**。
           原因：WebRTC 会占住音频会话，导致我们自己的采集引擎起不来
           （日志里网页在发帧、手机一帧都没发就是这个问题）。
           视频通话还是走 WebRTC，语音这条路不依赖 TURN/直连，运营商挡不住。 */
        if !isVideo {
            serverAudioOn = true
            CallAudioPipe.shared.onFrame = { [weak self] data in
                guard let self = self, !self.muted else { return }
                self.sendCall(["action": "audio", "data": data.base64EncodedString()])
            }
            CallAudioPipe.shared.start()
            if iAmCaller {
                /* ⚠ 关键：语音这条必须自己把「邀请」发出去。
                   以前这一支 return 得太早，发 invite 的代码在下面视频分支里 ——
                   结果是：主叫这边自己起了通道、界面显示「通话中」，对面手机**根本不响**
                   （看着就是「假通 / 打不出去」）。视频分支一直在发 invite，所以视频能响。 */
                sendCall(["action": "invite", "toUserId": peerId, "media": "audio"])
                tip = "正在呼叫…"
            } else {
                /* ⚠ 关键：必须告诉服务器「我接了」。
                   服务端只有把通话置成 active 才会转发音频帧（它是靠这个挡住
                   「没接通就往对方耳朵里灌声音」的），同时才会给主叫回一条
                   accepted —— 少了这一条，主叫那头会一直停在「正在呼叫…」，
                   而我们两边都在推帧、服务端一帧都不转，结果就是「都在通话中，
                   但一个字都听不见」（线上语音一直不通就是这个原因）。
                   语音走服务器转发，不需要 WebRTC 的 SDP，所以只发 accept 本身。 */
                sendCall(["action": "accept"])
                /* 被叫点了接听：直接进「通话中」并开始计时（语音这条路不依赖 ICE） */
                Ringtone.shared.stop()
                phase = .active
                tip = "通话中"
                ringTimer?.invalidate()
                ringTimer = nil
                connectTimer?.invalidate()
                connectTimer = nil
                startTimer()
            }
            reportMicState(prefix: "App 语音走服务器转发")
            return
        }

        let f = makeFactory()
        let cfg = RTCConfiguration()
        cfg.iceServers = iceServers
        /* 先问服务器两端是不是同一个网络：
           同一个网络（同一 Wi-Fi / 同一出口）→ 直连，快、不占服务器带宽；
           不同网络（4G ↔ 家里宽带）→ 强制走中继，不然直连经常只通一半甚至完全连不通。
           服务器是局域网地址（本机部署）时也直接走直连。 */
        let sameNet = await askSameNetwork(peerUserId: peerId)
        _ = sameNet        // 只记诊断用；策略上公网一律走中继（两端一致，避免半通）
        let host = API.shared.server.split(separator: ":").first.map(String.init) ?? ""
        let isLan = host == "localhost" || host.hasPrefix("127.") || host.hasPrefix("10.")
            || host.hasPrefix("192.168.") || host.hasPrefix("172.16") || host.hasPrefix("172.17")
            || host.hasPrefix("172.18") || host.hasPrefix("172.19") || host.hasPrefix("172.2")
            || host.hasPrefix("172.30") || host.hasPrefix("172.31")
        /* 以前公网强制「只走中继」，结果 4G↔宽带 这种组合经常连不上（一边走 TCP 中继、
           一边走 UDP 中继就配不上对）。现在改成 .all：直连能通用直连（快、不占带宽），
           连不上时 ICE 自己会退到中继候选。 */
        cfg.iceTransportPolicy = .all
        note("配置 iceServers=" + iceServers.map { ($0.urlStrings.first ?? "") }.joined(separator: ",")
             + " policy=all lan=" + (isLan ? "1" : "0"))
        cfg.sdpSemantics = .unifiedPlan
        let pc = f.peerConnection(with: cfg,
                                  constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
                                  delegate: self)
        self.pc = pc
        guard let pc = pc else { errorText = "初始化通话失败"; finish(tip: "初始化通话失败"); return }

        // 音频轨
        let audioSource = f.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let at = f.audioTrack(with: audioSource, trackId: "audio0")
        audioTrack = at
        pc.add(at, streamIds: ["chris"])

        // 视频轨（视频通话才有）
        if isVideo {
            let src = f.videoSource()
            videoSource = src
            let vt = f.videoTrack(with: src, trackId: "video0")
            localVideoTrack = vt
            pc.add(vt, streamIds: ["chris"])
            localVideo = vt
            startCapture(src)
        }

        if iAmCaller {
            pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] sdp, err in
                Task { @MainActor in
                    guard let self = self, let sdp = sdp else {
                        self?.errorText = err?.localizedDescription ?? "无法发起通话"
                        self?.finish(tip: "无法发起通话")
                        return
                    }
                    pc.setLocalDescription(sdp) { _ in
                        Task { @MainActor in
                            let local = pc.localDescription
                            self.sendCall(["action": "invite", "toUserId": self.peerId,
                                           "media": self.isVideo ? "video" : "audio",
                                           "sdp": ["type": local?.type.rawValue ?? "offer",
                                                   "sdp": local?.sdp ?? sdp.sdp]])
                        }
                    }
                }
            }
        } else {
            guard let offerSDP = remoteOfferSDP else { errorText = "来电信息不完整"; finish(tip: "来电信息不完整"); return }
            let offer = RTCSessionDescription(type: .offer, sdp: offerSDP)
            pc.setRemoteDescription(offer) { [weak self] err in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let err = err { self.errorText = "接通失败：\(err.localizedDescription)"; self.finish(tip: "接通失败"); return }
                    self.flushIce()
                    pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, _ in
                        Task { @MainActor in
                            guard let sdp = sdp else { self.finish(tip: "接通失败"); return }
                            pc.setLocalDescription(sdp) { _ in
                                Task { @MainActor in
                                    let local = pc.localDescription
                                    self.sendCall(["action": "accept",
                                                   "sdp": ["type": local?.type.rawValue ?? "answer",
                                                           "sdp": local?.sdp ?? sdp.sdp]])
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func flushIce() {
        guard let pc = pc, pc.remoteDescription != nil else { return }
        pendingIce.forEach { pc.add($0) { _ in } }
        pendingIce.removeAll()
    }

    private func startCapture(_ source: RTCVideoSource) {
        /* 套一层代理：开着「模糊背景」时，采集到的每一帧先过一遍背景模糊再进 WebRTC，
           关着的时候这层只是原样转发（几乎零开销）。 */
        let blur = BlurCapturer(inner: source)
        blurDelegate = blur
        let cap = RTCCameraVideoCapturer(delegate: blur)
        capturer = cap
        guard let dev = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
            ?? RTCCameraVideoCapturer.captureDevices().first,
              let fmt = bestFormat(for: dev) else { return }
        cap.startCapture(with: dev, format: fmt, fps: 30)
    }

    private func bestFormat(for dev: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: dev)
        return formats.min(by: { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return abs(Int(da.width) - 1280) + abs(Int(da.height) - 720)
                 < abs(Int(db.width) - 1280) + abs(Int(db.height) - 720)
        }) ?? formats.last
    }

    private func activateAudioSession() {
        let s = AVAudioSession.sharedInstance()
        /* 通话就该用 voiceChat 模式：不写 .defaultToSpeaker，默认走听筒（和微信一样，
           参考图里"扬声器已关"就是听筒），点扬声器再 overrideOutputAudioPort(.speaker)。 */
        try? s.setCategory(.playAndRecord, mode: .voiceChat,
                           options: [.allowBluetooth])
        try? s.setActive(true)
    }

    /* ------------------------------------------------------------------
       通话状态自愈：只要有一个异步回调把 phase 又设回「通话中」，
       用户就再也拨不出去（点拨打只弹一句「正在通话中」）。
       这里判断「状态不是 idle，但其实什么都没在跑」→ 直接复位。
       ------------------------------------------------------------------ */
    func resetIfStale() {
        guard phase != .idle else { return }
        let busy = (pc != nil) || usingTRTC || TRTCBridge.shared.joined
            || CallAudioPipe.shared.isRunning || !callId.isEmpty
        if busy { return }
        phase = .idle
        tip = ""
        errorText = nil
    }

    private func stopMedia() {
        capturer?.stopCapture()
        capturer = nil
        blurDelegate = nil
        if let pc = pc {
            pc.close()
        }
        pc = nil
        audioTrack = nil
        localVideoTrack = nil
        videoSource = nil
        remoteVideo = nil
        localVideo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finish(tip: String) {
        let wasIdle = (phase == .idle)
        let secs = seconds
        /* 通话结束：把锁屏上那条来电通知撤掉（不然会一直挂在那儿） */
        LocalNotify.clearCall(callId: callId)
        /* 通话结束：如果这时候人在后台，就把「保活」接回来（通话期间是关掉的） */
        if UIApplication.shared.applicationState != .active {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                KeepAlive.shared.start()
            }
        }
        failTask?.cancel()
        failTask = nil
        self.tip = tip
        Ringtone.shared.stop()
        ticker?.invalidate()
        ticker = nil
        ringTimer?.invalidate()
        ringTimer = nil
        connectTimer?.invalidate()
        connectTimer = nil
        /* 结束通话：把服务器转发的那条音频通道也关掉 */
        /* 关之前先把播放端的账留一份：收到多少帧、真正排进播放器多少帧 ——
           「两边都在发帧却没声音」这种问题下次直接就能定位到哪一头。 */
        if !wasIdle || seconds > 0 { diag.append(CallAudioPipe.shared.playDiag) }
        CallAudioPipe.shared.onFrame = nil
        CallAudioPipe.shared.stop()
        serverAudioOn = false
        /* 通话结束：把距离感应和模糊背景都关掉（不然会一直占着传感器/算力） */
        stopProximity()
        if blurBackground { setBlurBackground(false) }
        /* 腾讯云那路也退房 */
        if usingTRTC || TRTCBridge.shared.joined {
            TRTCBridge.shared.stop()
        }
        /* 把回调也摘掉：通话结束以后 TRTC 还可能补一个回调回来 */
        TRTCBridge.shared.onJoined = nil
        TRTCBridge.shared.onPeerChanged = nil
        usingTRTC = false
        trtcJoined = false
        stopMedia()
        /* 把这一通的 ICE 过程报给服务器（写进 call-trace.log），
           「一直在连接中」这种问题一看就知道卡在哪一步 */
        if !diag.isEmpty {
            let line = (iAmCaller ? "主叫" : "被叫") + (isVideo ? " 视频" : " 语音")
                + " 结果=" + (tip.isEmpty ? "结束" : tip) + " | " + diag.joined(separator: " ")
            diag.removeAll()
            Task { await API.shared.callDiag(line) }
        }
        callId = ""
        peerId = ""
        remoteOfferSDP = nil
        pendingIce.removeAll()
        seconds = 0
        muted = false
        micBlocked = false
        cameraOff = false
        minimized = false               // 挂起了也要收掉小浮窗，不然下一通一进来就是小窗
        if !wasIdle {
            phase = .idle
            /* 按最新要求：挂断以后不再弹「通话已结束」那种小卡片了。
               通话结果本来就会在聊天里留一条记录（已取消 / 对方无应答 / 通话时长 …）。 */
        }
    }

    /// 打不通时：先把原因留在通话页上显示一会儿，再自动挂断（默认 8 秒）。
    /// 这段时间里用户可以自己点挂断，也可以看着原因看完它自己收。
    private func failLater(_ tip: String, hold: Double = 8) {
        guard phase != .idle else { return }
        let text = tip.isEmpty ? "对方没有接听" : tip
        errorText = text
        self.tip = text
        failTask?.cancel()
        failTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard let self = self, !Task.isCancelled else { return }
            self.finish(tip: text)
        }
    }

    /// 记一条诊断（最多留 20 条），通话结束时一起报给服务器
    private func note(_ s: String) {
        diag.append(s)
        if diag.count > 20 { diag.removeFirst() }
    }

    /// 接通阶段盯 12 秒：还是「正在接通」就把最可能的原因写在屏幕上
    private func startConnectWatch() {
        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard self.phase == .connecting else { return }
                self.errorText = "声音一直连不上：① 两边都打开「设置 → CHRIS聊天 → 本地网络」；② 两台设备最好在同一个 Wi-Fi"
                self.tip = self.errorText ?? ""
            }
        }
    }

    private static func iceName(_ s: RTCIceConnectionState) -> String {
        switch s {
        case .new: return "new"
        case .checking: return "checking"
        case .connected: return "connected"
        case .completed: return "completed"
        case .failed: return "failed"
        case .disconnected: return "disconnected"
        case .closed: return "closed"
        case .count: return "count"
        @unknown default: return "?"
        }
    }

    private static func gatherName(_ s: RTCIceGatheringState) -> String {
        switch s {
        case .new: return "new"
        case .gathering: return "gathering"
        case .complete: return "complete"
        @unknown default: return "?"
        }
    }

    private func startTimer() {
        seconds = 0
        micDownTicks = 0
        /* 通话真的接通了：语音这一档把「贴耳切听筒」打开（视频通话不打开） */
        startProximity()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.seconds += 1
                self.checkMicAlive()
            }
        }
    }

    /// 通话中每秒对一次表：采集端活着就把「对方听不到你」收掉；
    /// 连着 5 秒起不来就挂上（自愈也没救回来的时候，用户至少知道问题在哪）。
    /// 只对语音通话看这条 —— 视频通话的麦克风归腾讯云 TRTC，本通道本来就不跑。
    private func checkMicAlive() {
        guard phase != .idle, !isVideo, !usingTRTC else { return }
        if CallAudioPipe.shared.isRunning {
            micDownTicks = 0
            if micBlocked { micBlocked = false }
        } else {
            micDownTicks += 1
            if micDownTicks >= 5, !micBlocked { micBlocked = true }
        }
    }

    /// 响了没人接：服务端 60 秒会自己收尾（记「对方无应答」），
    /// 这里 65 秒兜底一次——网络把服务端的 end 丢了也不会一直响下去。
    /// 主动方自己挂断时带 reason:'timeout'，让服务端记「对方无应答」而不是「已取消」。
    private func startRingTimeout() {
        ringTimer?.invalidate()
        ringTimer = Timer.scheduledTimer(withTimeInterval: 65, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard self.phase == .outgoing || self.phase == .incoming else { return }
                if !self.callId.isEmpty && self.iAmCaller {
                    self.sendCall(["action": "cancel", "reason": "timeout"])
                }
                self.finish(tip: self.iAmCaller ? "对方无应答" : "未接听")
            }
        }
    }
}

/* ---------------------------------------------------------- WebRTC 回调 */

extension CallCenter: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCSignalingState) { }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceConnectionState) {
        Task { @MainActor in self.note("ice=" + CallCenter.iceName(state)) }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Task { @MainActor in self.note("gathering=" + CallCenter.gatherName(newState)) }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let isRelay = candidate.sdp.contains("typ relay")
        let isSrflx = candidate.sdp.contains("typ srflx")
        /* 诊断里写清楚类型和协议（host/srflx/relay + udp/tcp）：
           以前只写前 24 个字符，看不出是 TCP 还是 UDP，排查时抓瞎。 */
        let parts = candidate.sdp.split(separator: " ")
        let typ = parts.count > 7 ? String(parts[7]) : "?"
        let proto = parts.count > 2 ? String(parts[2]) : "?"
        let addr = parts.count > 5 ? "\(parts[4]):\(parts[5])" : ""
        let brief = "\(typ)/\(proto) \(addr)"
        if isRelay || isSrflx {
            Task { @MainActor in
                if isRelay { self.relayOK = true }
                self.note("cand=" + brief)
            }
        } else {
            Task { @MainActor in self.note("cand=" + brief) }
        }
        let body: [String: Any] = ["action": "ice",
                                   "candidate": ["candidate": candidate.sdp,
                                                 "sdpMid": candidate.sdpMid ?? "0",
                                                 "sdpMLineIndex": Int(candidate.sdpMLineIndex)]]
        Task { @MainActor in self.sendCall(body) }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { }

    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) { }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        guard let track = stream.videoTracks.first else { return }
        Task { @MainActor in self.remoteVideo = track }
    }

    /// Unified Plan 下远端画面是从 receiver 来的（上面那个 stream 回调不一定触发）
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd receiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = receiver.track as? RTCVideoTrack else { return }
        Task { @MainActor in self.remoteVideo = track }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove receiver: RTCRtpReceiver, streams: [RTCMediaStream]) { }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) { }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in
            switch newState {
            case .connected:
                self.weakNet = false
                if self.phase != .active {
                    Ringtone.shared.stop()
                    self.phase = .active
                    self.tip = self.isVideo ? "视频通话中" : "通话中"
                    self.ringTimer?.invalidate()
                    self.ringTimer = nil
                    self.startTimer()
                    /* 接通也弹一下（同一个对话框，2 秒后自己关） */
                    self.showDialog(self.isVideo ? "视频通话已接通" : "语音通话已接通",
                                    detail: "", auto: 2)
                }
            case .failed:
                /* ⚠ 2026-10-13 稳定性（对标微信）：以前这里不分语音/视频，一律判「通话失败」。
                   但**语音通话的媒体走的是「服务器转发」那条独立通道**（不依赖 WebRTC/P2P），
                   WebRTC 挂了并不代表听不见/说不了 —— 直接判失败等于把还能用的通话掐掉。
                   现在：语音只提示弱网并重抢麦；视频才先兜底切腾讯云 TRTC，再判失败。 */
                if !self.isVideo {
                    self.weakNet = true
                    if self.tip != "通话中" { self.tip = "网络不太稳定，正在重连…" }
                    self.note("WebRTC failed（语音走转发通道，通话继续）")
                    CallAudioPipe.shared.resetHandOver()
                } else {
                    self.weakNet = true
                    if self.tip != "视频通话中" { self.tip = "网络不太稳定，正在重连…" }
                    self.note("WebRTC failed → 兜底切 TRTC")
                    if !self.usingTRTC { await self.startTRTCIfPossible() }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if self.phase == .active && !self.usingTRTC && self.pc?.connectionState == .failed {
                        self.failLater("通话连接失败，可能是网络挡住了", hold: 5)
                    }
                }
            case .disconnected:
                /* 弱网提示（微信也会写「网络不佳」）：**宽限从 3 秒放到 8 秒** ——
                   微信切网那一下（Wi-Fi→4G）要几秒才接回来，3 秒就挂断太急。 */
                self.weakNet = true
                if self.tip != "通话中" && self.tip != "视频通话中" { self.tip = "网络不太稳定，正在重连…" }
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if self.phase == .active && self.pc?.connectionState == .disconnected {
                    if self.isVideo && !self.usingTRTC {
                        self.note("视频断线 8 秒 → 兜底切 TRTC")
                        await self.startTRTCIfPossible()
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                    if self.phase == .active && !self.usingTRTC && self.pc?.connectionState == .disconnected {
                        self.finish(tip: "通话已断开")
                    }
                }
            default:
                break
            }
        }
    }
    /* ---------------------------------------------------------- 腾讯云 TRTC
       进房成功**不马上切**：先看对端有没有也进到这个房间。
         · 对端也进来了 → 媒体切给 TRTC（把我们自己那两路停掉，免得叠音）
         · 对端没进来（旧版本 / 取不到票 / 网络不通）→ 继续走原来的
           WebRTC（视频）+ 服务器转发语音，通话照样通，不会变哑巴。 */

    private func startTRTCIfPossible() async {
        /* ⚠ 语音**不进 TRTC 房间**（线上实测后定的）：TRTC 用 role=anchor 一进房
           就会自己开麦采集，把我们的 AVCaptureSession 挤成空壳，我们抢麦失败 →
           重试时关掉音频会话 → 播放引擎被掐停 → 「两边都在发帧却没声音」。
           只有视频走 TRTC（视频没有服务器转发这条退路）。 */
        guard isVideo else { return }
        /* 视频：进房不采集（TRTCBridge.start 只 enterRoom）。
           以前栽过的坑：TRTC 用 role=anchor 一进房就自己开麦采集，把我们的
           AVCaptureSession 挤成空壳（isRunning=true、采集=ok，却一个 buffer 都不回调），
           服务器一帧都收不到 —— 所以这里的顺序必须是：
             ① 先只进房（不采集），自建转发继续跑着兜底；
             ② 确认**对端也在同一个房间里**之后，才 switchMediaToTRTC()：
                先停掉自建那两路，再 activate() 让 TRTC 开麦。
           麦克风始终只有一个主人，不会出现两个引擎抢麦。
           对端是旧版本 / 网页版（不会进这个房间）→ 一直走自建转发。 */
        guard !trtcJoined, !usingTRTC, !callId.isEmpty else { return }
        let bridge = TRTCBridge.shared
        bridge.onJoined = { [weak self] ok in
            guard let self = self else { return }
            guard ok else { return }
            /* 通话已经结束了（TRTC 的回调是异步的，可能迟到）：什么都不做，
               否则会把 phase 又设回「通话中」，用户就再也拨不出去了。 */
            guard self.phase != .idle, !self.callId.isEmpty else { return }
            self.trtcJoined = true
            self.note("TRTC 已进房（等对端）")
            /* 对端已经在房里了（比如我先退再进）：直接切 */
            if TRTCBridge.shared.peerInRoom { self.switchMediaToTRTC() }
        }
        bridge.onPeerChanged = { [weak self] inRoom in
            guard let self = self else { return }
            guard inRoom else { return }
            guard self.phase != .idle, !self.callId.isEmpty else { return }
            if self.trtcJoined { self.switchMediaToTRTC() }
            if self.phase != .active {
                Ringtone.shared.stop()
                self.phase = .active
                self.tip = "通话中"
                self.ringTimer?.invalidate()
                self.ringTimer = nil
                self.connectTimer?.invalidate()
                self.connectTimer = nil
                self.startTimer()
            }
        }
        let ok = await bridge.start(roomSeed: callId, video: isVideo)
        if !ok {
            note("TRTC 用不了：" + bridge.lastError + "（继续走老路）")
        } else {
            note("TRTC 已请求进房（room=" + callId + "）")
            /* 关键：TRTC 进房后会自己抢麦克风，而我们这会儿还在走自己的转发通道
               （对端没进房）—— 不把它按住，我们自己的采集就会「拿不到麦克风输入」，
               结果就是「通话中但两边都没声音」。等真切到 TRTC 时它会重新打开。 */
            TRTCBridge.shared.standByForLocalMedia()
            /* 把 TRTC 那点状态也报上来：排查「到底进没进同一个房间」就看这几行 */
            let b = TRTCBridge.shared
            Task { await API.shared.callDiag("TRTC 进房 room=" + self.callId
                + " 我方ID=" + b.userId
                + " 对端在房里=" + (b.peerInRoom ? "是" : "否")
                + (b.lastError.isEmpty ? "" : " 错误=" + b.lastError)) }
            /* 视频通话：视频**没有**「服务器转发」这条退路（只有语音有），
               而我们这边已经进房了 —— 再给 6 秒等对端进房；等不到就直接切 TRTC，
               因为对端若是新版本（也进了房）我们只是漏收事件，切过去就通了。 */
            if isVideo {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard let self = self, self.trtcJoined, !self.usingTRTC,
                          self.phase != .idle, !self.callId.isEmpty else { return }
                    self.note("6 秒没等到对端进房，直接切 TRTC（对端可能是旧版本）")
                    self.switchMediaToTRTC()
                }
            }
            /* 8 秒还没等到对端进房，就当对面不是 TRTC 版本，把老路继续用着 */
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self = self, !self.usingTRTC, !Task.isCancelled else { return }
                self.note("对端没进 TRTC 房间（可能是旧版本）→ 继续走服务器转发/WebRTC")
            }
        }
    }

    /// 确认对端也在 TRTC 房间里了：把媒体完全交给腾讯云
    private func switchMediaToTRTC() {
        guard !usingTRTC, phase != .idle, !callId.isEmpty else { return }
        /* 语音永远不切 TRTC（切过去就得两个引擎抢麦克风，实测就是「都没声音」） */
        guard isVideo else { return }
        usingTRTC = true
        note(isVideo ? "对端也在腾讯云房间里 → 媒体切到 TRTC ✓"
                     : "对端也在腾讯云房间里 → 语音切到 TRTC ✓")
        /* 关掉我们自己那两路，避免叠音 + 抢摄像头 */
        /* 语音：不是「停一下」而是「交出去」—— 连抢麦重试都禁止，
           否则这边还在抢麦克风，TRTC 开了麦却采不到音（两边都没声音）。 */
        CallAudioPipe.shared.handOverToTRTC()
        serverAudioOn = false
        audioTrack?.isEnabled = false
        localVideoTrack?.isEnabled = false
        capturer?.stopCapture()
        /* 我们自己不采集了，才让 TRTC 开始采集（避免两个引擎抢麦克风/摄像头）。
           语音要多等一拍：我们刚把 AVCaptureSession 停下来，系统释放麦克风是异步的，
           紧接着 activate 有概率抢不到（表现就是「切过去之后对面反而听不见了」）。 */
        let waitNs: UInt64 = isVideo ? 0 : 300_000_000
        Task { @MainActor [weak self] in
            if waitNs > 0 { try? await Task.sleep(nanoseconds: waitNs) }
            guard let self = self, self.usingTRTC,
                  self.phase != .idle, !self.callId.isEmpty else { return }
            /* 语音：等我们自己的采集**真的**停下来再让 TRTC 开麦（系统释放麦克风是异步的） */
            if !self.isVideo {
                let t0 = Date()
                while CallAudioPipe.shared.isRunning, Date().timeIntervalSince(t0) < 2.0 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            TRTCBridge.shared.activate()
            TRTCBridge.shared.setMuted(self.muted)
            TRTCBridge.shared.setSpeaker(self.speakerOn)
        }
        if phase != .active {
            Ringtone.shared.stop()
            phase = .active
            tip = "通话中"
            ringTimer?.invalidate()
            ringTimer = nil
            connectTimer?.invalidate()
            connectTimer = nil
            startTimer()
        }
    }
}

/* ---------------------------------------------------------- 小工具 */

enum Permission {
    /// 申请麦克风 / 摄像头权限
    static func ask(_ kind: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: kind) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: kind) { ok in cont.resume(returning: ok) }
            }
        default: return false
        }
    }
}

enum UINotification {
    /// 来电震一下（不依赖通知权限）
    static func buzz() {
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.impactOccurred()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
}
