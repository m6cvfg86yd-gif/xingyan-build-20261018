import Foundation
import SwiftUI
import WebRTC
import AVFoundation
import Combine

/* ============================================================
   真视频直播（直播专场）
   主播：手机相机 + 麦克风 → 每个观众一路 WebRTC 连接（走我们自己的 TURN 中转）
   观众：进房间就自动向主播发 offer（recvOnly），收到画面直接铺满屏幕
   信令：复用那条长连接，type=live / action=sig（offer / answer / ice）
   ============================================================ */

@MainActor
final class LiveCenter: NSObject, ObservableObject {
    static let shared = LiveCenter()

    @Published private(set) var publishing = false      // 我在推流
    @Published private(set) var watching = false        // 我在看
    @Published private(set) var roomId = ""
    @Published private(set) var hostId = ""
    @Published private(set) var localVideo: RTCVideoTrack?
    @Published private(set) var remoteVideo: RTCVideoTrack?
    @Published private(set) var viewers = 0

    private var factory: RTCPeerConnectionFactory?
    /// 主播：每个观众一路；观众：只有一路（key = hostId）
    private var peers: [String: RTCPeerConnection] = [:]
    private var cam: RTCCameraVideoCapturer?
    private var videoSource: RTCVideoSource?
    private var videoTrack: RTCVideoTrack?
    private var audioTrack: RTCAudioTrack?
    private var ice: [RTCIceServer] = []
    private var sub: AnyCancellable?

    private override init() {
        super.init()
        sub = Realtime.shared.$event
            .receive(on: RunLoop.main)
            .sink { [weak self] ev in
                guard ev.type == "live" else { return }
                self?.handle(ev)
            }
        Task { await loadIce() }
    }

    /* ---------------------------------------------------------- 对外 */

    /// 开播：打开相机，等观众进来（每个观众 offer 一次）
    func startPublish(room: String) async -> Bool {
        guard await Permission.ask(.audio), await Permission.ask(.video) else { return false }
        roomId = room
        publishing = true
        watching = false
        hostId = ""
        activateAudio()
        buildTracks()
        send(["action": "hello"])                 // 告诉服务器「这个房间有人在推流」
        return true
    }

    func stopPublish() {
        send(["action": "bye"])
        peers.keys.forEach { peers[$0]?.close(); peers[$0] = nil }
        stopCapture()
        publishing = false
        roomId = ""
        localVideo = nil
        viewers = 0
        deactivateAudio()
    }

    /// 看直播：向主播发一个 recvOnly 的 offer
    func startWatch(room: String, host: String) {
        stopWatch()
        roomId = room
        hostId = host
        watching = true
        activateAudio()
        let pc = makePC(peer: host, publish: false)
        /* 观众只收不发：两条 recvOnly 的收发器 */
        let vi = RTCRtpTransceiverInit()
        vi.direction = .recvOnly
        _ = pc.addTransceiver(of: .video, init: vi)
        let ai = RTCRtpTransceiverInit()
        ai.direction = .recvOnly
        _ = pc.addTransceiver(of: .audio, init: ai)
        pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] sdp, _ in
            Task { @MainActor in
                guard let self = self, let sdp = sdp else { return }
                pc.setLocalDescription(sdp) { _ in
                    Task { @MainActor in self.send(["action": "sig", "to": host, "sigKind": "offer",
                                                    "sdp": ["type": "offer", "sdp": sdp.sdp]]) }
                }
            }
        }
    }

    func stopWatch() {
        if !hostId.isEmpty { send(["action": "bye", "to": hostId]) }
        peers.values.forEach { $0.close() }
        peers.removeAll()
        remoteVideo = nil
        watching = false
        hostId = ""
        roomId = ""
        deactivateAudio()
    }

    func flipCamera() {
        guard let cap = cam, let dev = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
                ?? RTCCameraVideoCapturer.captureDevices().first else { return }
        guard let fmt = RTCCameraVideoCapturer.supportedFormats(for: dev).last else { return }
        cap.startCapture(with: dev, format: fmt, fps: 24)
    }

    /* ---------------------------------------------------------- 内部 */

    private func loadIce() async {
        var list: [RTCIceServer] = [
            RTCIceServer(urlStrings: ["stun:stun.miwifi.com:3478", "stun:stun.cloudflare.com:3478"])
        ]
        let hostOnly = API.shared.server.split(separator: ":").first.map(String.init) ?? ""
        if !hostOnly.isEmpty {
            list.insert(RTCIceServer(urlStrings: ["turn:\(hostOnly):3478?transport=udp"],
                                     username: "chris", credential: "chris1234"), at: 0)
        }
        if let b = await API.shared.branding(),
           let raw = b.iceServers?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
           let data = raw.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var out: [RTCIceServer] = []
            for it in arr {
                var urls: [String] = []
                if let one = it["urls"] as? String { urls = [one] }
                else if let many = it["urls"] as? [String] { urls = many }
                if urls.isEmpty { continue }
                out.append(RTCIceServer(urlStrings: urls, username: it["username"] as? String,
                                        credential: it["credential"] as? String))
            }
            if !out.isEmpty { list = out }
        }
        ice = list
    }

    private func makeFactory() -> RTCPeerConnectionFactory {
        if let f = factory { return f }
        let f = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
        factory = f
        return f
    }

    private func buildTracks() {
        let f = makeFactory()
        if videoTrack == nil {
            let src = f.videoSource()
            videoSource = src
            let t = f.videoTrack(with: src, trackId: "lv-video")
            videoTrack = t
            localVideo = t
            startCapture(src)
        }
        if audioTrack == nil {
            let a = f.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            audioTrack = f.audioTrack(with: a, trackId: "lv-audio")
        }
    }

    private func startCapture(_ src: RTCVideoSource) {
        let cap = RTCCameraVideoCapturer(delegate: src)
        cam = cap
        let devs = RTCCameraVideoCapturer.captureDevices()
        guard let dev = devs.first(where: { $0.position == .back }) ?? devs.first,
              let fmt = RTCCameraVideoCapturer.supportedFormats(for: dev).last else { return }
        cap.startCapture(with: dev, format: fmt, fps: 24)
    }

    private func stopCapture() {
        cam?.stopCapture()
        cam = nil
        videoTrack = nil
        audioTrack = nil
        videoSource = nil
    }

    private func activateAudio() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetooth])
        try? s.setActive(true)
    }
    private func deactivateAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func makePC(peer: String, publish: Bool) -> RTCPeerConnection {
        if let old = peers[peer] { old.close() }
        let cfg = RTCConfiguration()
        cfg.iceServers = ice
        cfg.sdpSemantics = .unifiedPlan
        cfg.iceTransportPolicy = .all
        let pc = makeFactory().peerConnection(with: cfg, constraints: RTCMediaConstraints(
            mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)!
        if publish, let v = videoTrack, let a = audioTrack {
            pc.add(v, streamIds: ["live"])
            pc.add(a, streamIds: ["live"])
        }
        peers[peer] = pc
        return pc
    }

    private func send(_ body: [String: Any]) {
        var msg: [String: Any] = ["type": "live", "roomId": roomId]
        body.forEach { msg[$0.key] = $0.value }
        Realtime.shared.sendJSON(msg)
    }

    private func handle(_ ev: PushEvent) {
        let from = ev.liveFromId
        guard !from.isEmpty else { return }
        switch ev.liveSigKind {
        case "offer":
            /* 我是主播：这个观众要画面，建一路给他 */
            guard publishing, !ev.liveSDP.isEmpty else { return }
            let pc = makePC(peer: from, publish: true)
            let offer = RTCSessionDescription(type: .offer, sdp: ev.liveSDP)
            pc.setRemoteDescription(offer) { _ in
                pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, _ in
                    guard let sdp = sdp else { return }
                    pc.setLocalDescription(sdp) { _ in
                        Task { @MainActor in
                            self.viewers = self.peers.count
                            self.send(["action": "sig", "to": from, "sigKind": "answer",
                                       "sdp": ["type": "answer", "sdp": sdp.sdp]])
                        }
                    }
                }
            }
        case "answer":
            guard watching, let pc = peers[from], !ev.liveSDP.isEmpty else { return }
            pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: ev.liveSDP)) { _ in }
        case "ice":
            guard let pc = peers[from], !ev.liveCandidate.isEmpty,
                  let data = ev.liveCandidate.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let cand = RTCIceCandidate(sdp: (o["candidate"] as? String) ?? "",
                                       sdpMLineIndex: Int32((o["sdpMLineIndex"] as? Int) ?? 0),
                                       sdpMid: (o["sdpMid"] as? String) ?? "0")
            pc.add(cand) { _ in }
        case "bye":
            if let pc = peers[from] { pc.close(); peers[from] = nil }
            if publishing { viewers = peers.count }
            if watching, from == hostId { remoteVideo = nil }
        default:
            if ev.liveAction == "hostGone", watching { remoteVideo = nil }
        }
    }
}

extension LiveCenter: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCSignalingState) { }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceConnectionState) { }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceGatheringState) { }
    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) { }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) { }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) { }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        guard let t = stream.videoTracks.first else { return }
        Task { @MainActor in
            if LiveCenter.shared.watching { LiveCenter.shared.setRemote(t) }
        }
    }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd receiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let t = receiver.track as? RTCVideoTrack else { return }
        Task { @MainActor in
            if LiveCenter.shared.watching { LiveCenter.shared.setRemote(t) }
        }
    }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove receiver: RTCRtpReceiver) { }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            let c = LiveCenter.shared
            guard !c.roomId.isEmpty else { return }
            /* 主播：发给所有观众；观众：发给主播 */
            if c.publishing {
                for pid in c.peerIds() {
                    c.send(["action": "sig", "to": pid, "sigKind": "ice",
                            "candidate": ["candidate": candidate.sdp,
                                          "sdpMid": candidate.sdpMid ?? "0",
                                          "sdpMLineIndex": Int(candidate.sdpMLineIndex)]])
                }
            } else if !c.hostId.isEmpty {
                c.send(["action": "sig", "to": c.hostId, "sigKind": "ice",
                        "candidate": ["candidate": candidate.sdp,
                                      "sdpMid": candidate.sdpMid ?? "0",
                                      "sdpMLineIndex": Int(candidate.sdpMLineIndex)]])
            }
        }
    }

    fileprivate func setRemote(_ t: RTCVideoTrack) { remoteVideo = t }
    fileprivate func peerIds() -> [String] { Array(peers.keys) }
}
