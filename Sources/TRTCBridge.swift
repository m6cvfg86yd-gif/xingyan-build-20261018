import Foundation
import UIKit
import SwiftUI
import TXLiteAVSDK_TRTC

/* ============================================================
   腾讯云 TRTC（音视频通话）

   为什么要它：自己的 TURN 走 UDP 被机房/家宽挡住的时候，跨网通话就连不上
   （实测：3478/udp 从外网没有回包）。TRTC 走腾讯云的接入点，不依赖我们自己的中继。

   怎么用：进房要三样东西（sdkAppId / userId / userSig），这三样都由我们服务器签
   （见 /api/trtc/sig，密钥只在服务端）。房间号按「这次通话的 callId」算，两边一致。

   和老的 WebRTC 怎么相处：TRTC **进房成功才接管**媒体；进不去（没配置、网络不通）
   就什么也不动，继续走原来那套 WebRTC + 服务器转发语音，保证不退化。
   ============================================================ */

@MainActor
final class TRTCBridge: NSObject, ObservableObject {
    static let shared = TRTCBridge()

    /// 已经进房（媒体由 TRTC 负责）
    @Published private(set) var joined = false
    /// 远端画面（TRTC 自己往这个 view 里画）
    @Published private(set) var remoteView: UIView? = nil
    /* ---------------- 群会议（多人）：每个远端用户一路画面 ----------------
       1 对 1 用上面那个 remoteView（不动）；群会议用这张表，每人一个 view。
       回调里已经带 userId，所以只要按 userId 分派就行。 */
    private var meetingViews: [String: UIView] = [:]
    /// 会议里现在有画面的远端用户（宫格按这个顺序摆）
    @Published private(set) var meetingUsers: [String] = []

    /// 群会议：要某人的画面；第一次调用会建 view 并让 TRTC 往里画
    func meetingView(for userId: String) -> UIView {
        if let v = meetingViews[userId] { return v }
        let v = UIView()
        v.backgroundColor = .black
        meetingViews[userId] = v
        if !meetingUsers.contains(userId) { meetingUsers.append(userId) }
        cloud?.startRemoteView(userId, view: v)
        return v
    }

    /// 群会议：散会（把所有人的画面都收掉，回到 1 对 1 那套干净状态）
    func stopMeetingViews() {
        for (id, _) in meetingViews { cloud?.stopRemoteView(id) }
        meetingViews.removeAll()
        meetingUsers.removeAll()
    }
    /// 本地画面（小窗）
    @Published private(set) var localView: UIView? = nil
    /// 对端有没有人在房间里
    @Published private(set) var peerInRoom = false
    /// 最近一次错误（给通话页显示）
    @Published private(set) var lastError = ""
    /// 我方在 TRTC 里的 userId（就是我们的用户 id，排查用）
    @Published private(set) var userId = ""

    /// 进房 / 退房回调（CallCenter 用它切状态）
    var onJoined: ((Bool) -> Void)?
    var onPeerChanged: ((Bool) -> Void)?

    private var cloud: TRTCCloud?
    private var roomSeed = ""
    private var isVideo = false
    private var busy = false
    /// 房间里那个对端的 userId（退房前要把它的画面停掉）
    private var peerUserId = ""
    /// 是否已经开始真正采集（麦克风 / 摄像头）
    private var active = false
    /// 「音视频通话」设置改了（清晰度 / 镜像 / 美颜）：通话中立刻套上
    private var prefsObserver: NSObjectProtocol? = nil

    private override init() { super.init() }

    /// 进房。返回 false 表示「TRTC 用不了」，调用方继续用老路。
    @discardableResult
    func start(roomSeed: String, video: Bool) async -> Bool {
        guard !joined, !busy else { return joined }
        busy = true
        defer { busy = false }
        self.roomSeed = roomSeed
        isVideo = video
        lastError = ""

        let cfg: API.TRTCSig
        do {
            cfg = try await API.shared.trtcSig(room: roomSeed, media: video ? "video" : "audio")
        } catch {
            lastError = (error as? APIError)?.errorDescription ?? "TRTC 取不到签名"
            return false
        }
        guard cfg.sdkAppId > 0, !cfg.userSig.isEmpty, cfg.roomId > 0 else {
            lastError = "TRTC 参数不完整"
            return false
        }

        let params = TRTCParams()
        params.sdkAppId = UInt32(cfg.sdkAppId)
        params.userId = cfg.userId
        userId = cfg.userId
        params.userSig = cfg.userSig
        params.roomId = UInt32(cfg.roomId)
        params.role = .anchor

        let c = TRTCCloud.sharedInstance()
        c.delegate = self
        cloud = c
        if prefsObserver == nil {
            prefsObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("chrisCallPrefsChanged"), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.applyVideoPrefs()
                    self?.applyBeauty()
                }
            }
        }
        remoteView = UIView()
        localView = UIView()
        /* 真人变声：进房就按「设置 → 通用 → 语音变声」选好的那个套上。
           用的是 TRTC 自带的声学变声（大叔/萝莉/外国腔/空灵）+ 混响，音质干净、
           不是机器人那种电子音；通话中改预设也会立刻生效（见 VoiceChangerStore.select）。 */
        applyVoiceEffect()
        /* 先只「进房」，**不采集**麦克风和摄像头 ——
           不然会和我们自己的 WebRTC / 服务器转发抢麦克风（两个引擎同时开就是沙沙声或没声）。
           等确认对端也在这个房间里，再调 activate() 真正开始采集。 */
        c.enterRoom(params, appScene: video ? .videoCall : .audioCall)
        return true
    }

    /// 对端也在房间里了：这时候才真正开始采集（麦克风 + 视频通话的摄像头）
    func activate() {
        guard let c = cloud, joined, !active else { return }
        active = true
        c.startLocalAudio(.default)
        c.muteLocalAudio(false)
        if isVideo {
            /* 采集之前先把清晰度 / 镜像 / 美颜套上（改完不用挂断重打） */
            applyVideoPrefs()
            c.startLocalPreview(true, view: localView)
            /* 模糊背景开着的话，采集开始之后要把处理回调挂上 */
            if VideoBlur.shared.enabled { setBackgroundBlur(true) }
        }
    }

    /* ---------------- 视频清晰度 / 镜像 / 美颜（对齐微信） ----------------
       全用 rawValue 构造枚举：TRTC 的 Swift 名字在不同版本里改过好几回
       （下面 setSpeaker 也是这个理由），原始值是从 SDK 头文件里核对出来的：
         TRTCVideoResolution: 640_360=108 · 1280_720=112 · 1920_1080=114
         TRTCVideoResolutionMode: Landscape 0 · Portrait 1
         TRTCVideoFillMode: Fill 0 · Fit 1
         TRTCVideoMirrorType: Auto 0 · Enable 1 · Disable 2
         TXBeautyStyle: Smooth 0 · Nature 1
       ⚠ 720p/1080p 比默认 360p 吃流量，所以默认给「高清」，用户可在
         我 → 设置 → 功能 → 音视频通话 里切。 */
    func applyVideoPrefs() {
        guard let c = cloud, isVideo else { return }
        let p = CallPrefs.encoderParams()
        let enc = TRTCVideoEncParam()
        if let res = TRTCVideoResolution(rawValue: p.resolution) { enc.videoResolution = res }
        if let mode = TRTCVideoResolutionMode(rawValue: 1) { enc.resMode = mode }   // 竖屏
        enc.videoFps = p.fps
        enc.videoBitrate = p.bitrate
        c.setVideoEncoderParam(enc)

        let r = TRTCRenderParams()
        if let fill = TRTCVideoFillMode(rawValue: 0) { r.fillMode = fill }
        if let mir = TRTCVideoMirrorType(rawValue: CallPrefs.mirror ? 1 : 2) { r.mirrorType = mir }
        c.setLocalRenderParams(r)

        applyBeauty()
    }

    /// 美颜（0 关 / 1 低 / 2 中 / 3 高 → 磨皮 0/3/6/9、提亮 0/1.5/3/4.5）
    func applyBeauty() {
        guard let mgr = cloud?.getBeautyManager() else { return }
        if let style = TXBeautyStyle(rawValue: 1) { mgr.setBeautyStyle(style) }   // 自然
        let lv = Float(CallPrefs.beauty)
        mgr.setBeautyLevel(lv * 3)
        mgr.setWhitenessLevel(lv * 1.5)
    }

    /* ---------------- 视频通话的「模糊背景」（对齐微信那一档） ----------------
       把本地采集的画面交给自己的处理回调（VideoBlur）：
       TRTC 那边按 BGRA 的 PixelBuffer 回帧，我们糊完背景再写回 dstFrame。
       关掉时把回调摘掉，采集路径回到 SDK 默认（少一层处理、更省电）。 */
    func setBackgroundBlur(_ on: Bool) {
        guard let c = cloud, let fmt = TRTCVideoPixelFormat(rawValue: 6),
              let buf = TRTCVideoBufferType(rawValue: 1) else { return }   // 6=32BGRA 1=PixelBuffer
        if on, isVideo {
            c.setLocalVideoProcessDelegete(VideoBlur.shared, pixelFormat: fmt, bufferType: buf)
        } else {
            c.setLocalVideoProcessDelegete(nil, pixelFormat: fmt, bufferType: buf)
            VideoBlur.shared.reset()
        }
    }

    /// 把我选的变声预设套到通话上（TRTC 音频效果管理器）。
    /// 原声 = 两个都设 0，等于关掉。房间里随时能改，对端立刻听到新声音。
    func applyVoiceEffect() {
        guard let mgr = cloud?.getAudioEffectManager() else { return }
        let e = VoiceChangerStore.shared.current
        if let t = TXVoiceChangeType(rawValue: e.trtcChange) {
            mgr.setVoiceChangerType(t)
        }
        if let r = TXVoiceReverbType(rawValue: e.trtcReverb) {
            mgr.setVoiceReverbType(r)
        }
    }

    /// 进房之后先「让出」麦克风和摄像头：
    /// TRTC 一进房就会自己开本地音频采集，把我们自己的采集通道挤掉
    /// （日志里「拿不到麦克风输入」就是这么来的）。
    /// 这时候媒体还没切给 TRTC（对端没进房），本地采集交给我们自己的通道，
    /// 等真的切过去时 activate() 会把 TRTC 的采集重新打开。
    func standByForLocalMedia() {
        guard let c = cloud, joined else { return }
        /* 没开始采集过就别去 stop：TRTC SDK 对「没 start 就 stop」比较敏感，
           少调一次少一分崩的风险（我们这会儿本来也没在采集）。 */
        guard active else { return }
        c.stopLocalAudio()
        if isVideo { c.stopLocalPreview() }
        active = false
    }

    func stop() {
        if let ob = prefsObserver {
            NotificationCenter.default.removeObserver(ob)
            prefsObserver = nil
        }
        cloud?.stopLocalPreview()
        cloud?.stopLocalAudio()
        if !peerUserId.isEmpty { cloud?.stopRemoteView(peerUserId) }
        cloud?.exitRoom()
        cloud?.delegate = nil
        cloud = nil
        TRTCCloud.destroySharedInstance()
        joined = false
        peerInRoom = false
        peerUserId = ""
        active = false
        remoteView = nil
        localView = nil
    }

    /* ---------------- 通话中那几个开关 ---------------- */

    func setMuted(_ mute: Bool) {
        cloud?.muteLocalAudio(mute)
    }

    func setCameraOff(_ off: Bool) {
        guard isVideo else { return }
        if off { cloud?.stopLocalPreview() } else { cloud?.startLocalPreview(true, view: localView) }
    }

    func flipCamera() {
        cloud?.switchCamera()
    }

    func setSpeaker(_ on: Bool) {
        /* 头文件里：TRTCAudioModeSpeakerphone = 0（外放）、TRTCAudioModeEarpiece = 1（听筒）。
           这里按原始值构造，省得被 Swift 把枚举名改来改去。 */
        if let route = TRTCAudioRoute(rawValue: on ? 0 : 1) {
            cloud?.setAudioRoute(route)
        }
    }
}

extension TRTCBridge: TRTCCloudDelegate {
    nonisolated func onEnterRoom(_ result: Int) {
        Task { @MainActor in
            if result > 0 {
                self.joined = true
                self.lastError = ""
                self.onJoined?(true)
            } else {
                self.joined = false
                self.lastError = "TRTC 进房失败（错误码 \(result)）"
                self.onJoined?(false)
            }
        }
    }

    nonisolated func onExitRoom(_ reason: Int) {
        Task { @MainActor in
            self.joined = false
            self.peerInRoom = false
            self.onJoined?(false)
        }
    }

    nonisolated func onRemoteUserEnterRoom(_ userId: String) {
        Task { @MainActor in
            self.peerUserId = userId
            self.peerInRoom = true
            self.onPeerChanged?(true)
        }
    }

    nonisolated func onRemoteUserLeaveRoom(_ userId: String, reason: Int) {
        Task { @MainActor in
            self.peerInRoom = false
            self.onPeerChanged?(false)
        }
    }

    nonisolated func onUserVideoAvailable(_ userId: String, available: Bool) {
        Task { @MainActor in
            /* 群会议：每个远端用户一路画面（1 对 1 走下面原来的 remoteView，互不影响） */
            if let v = self.meetingViews[userId] {
                if available { self.cloud?.startRemoteView(userId, view: v) }
                else { self.cloud?.stopRemoteView(userId) }
                return
            }
            if available, let v = self.remoteView {
                self.peerUserId = userId
                self.cloud?.startRemoteView(userId, view: v)
                self.peerInRoom = true
                self.onPeerChanged?(true)
            } else {
                self.cloud?.stopRemoteView(userId)
            }
        }
    }

    /// 远端音频可用也算「对端在房间里」—— 光靠 onRemoteUserEnterRoom 会漏：
    /// 如果对端比我们先进房，那个「进场」事件我们收不到（TRTC 只推后来的人）。
    nonisolated func onUserAudioAvailable(_ userId: String, available: Bool) {
        Task { @MainActor in
            guard available else { return }
            self.peerUserId = userId
            self.peerInRoom = true
            self.onPeerChanged?(true)
        }
    }

    nonisolated func onError(_ errCode: Int, errMsg: String?, extInfo: [String: Any]?) {
        Task { @MainActor in
            self.lastError = "TRTC 错误 \(errCode)：" + (errMsg ?? "")
        }
    }
}

/* ============================================================
   把 TRTC 的 UIView 塞进 SwiftUI（远端大画面 / 本地小窗都用它）
   ============================================================ */

struct TRTCVideoView: UIViewRepresentable {
    let view: UIView?

    func makeUIView(context: Context) -> UIView {
        let holder = UIView()
        holder.backgroundColor = .clear
        if let v = view {
            v.frame = holder.bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            holder.addSubview(v)
        }
        return holder
    }

    func updateUIView(_ holder: UIView, context: Context) {
        guard let v = view else { return }
        if v.superview !== holder {
            v.frame = holder.bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            holder.addSubview(v)
        }
    }
}
