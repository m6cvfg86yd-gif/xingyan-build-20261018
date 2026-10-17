import Foundation
import SwiftUI

/// 服务器推送过来的一件事（收到新消息、转账、朋友圈、余额变动…）
struct PushEvent: Equatable {
    var type = ""
    /// 通用动作（好友 accepted / request / meta，朋友圈 like / comment 等）
    var action = ""
    var chatId = ""
    var fromId = ""
    var balance: Double? = nil
    var announce = ""
    var user: User? = nil
    /// 朋友圈有没有新的（服务器在 ready 里给；有就给「发现」挂红点）
    var momentUnread: Int? = nil
    /// 朋友圈「消息列表」（谁赞了/评论了我）的未读数：朋友圈右上角那个小信封上的红点
    var momentNoticeUnread: Int? = nil
    /// 阅后即焚：服务端刚销毁了这几条消息（客户端把它们从列表里去掉）
    var burnIds: [String] = []
    /// 朋友圈来了一条新通知（点赞/评论）：直接带回来，页面不用再拉一次
    var momentNotice: MomentNotice? = nil
    /// 群通话里每个人的音量（id → 0…1）：「谁在说话」高亮用
    var callLevels: [String: Double] = [:]
    /// 待处理的好友申请数量（服务器在 ready 里给；手机在后台没收到推送时靠它补上通讯录红点）
    var friendRequests: Int? = nil
    /// 转账推过来的东西（谁发的、什么状态、多少钱）：对方收款时付款方这边要变气泡 + 弹提示
    var transferFromId = ""
    var transferStatus = ""
    var transferAmount: Double? = nil
    var callId = ""
    var callAction = ""
    var callMedia = ""
    var callPeerId = ""
    var callPeerName = ""
    var callPeerAvatar = ""
    var callError = ""
    /// 对方那边的状态（和微信一样画出来）：静音中 / 摄像头关着 / 现在是视频还是语音
    var callPeerMuted = false
    var callPeerCameraOff = false
    var callPeerVideo = false
    /// 群语音：房间号 / 群 id / 房里现在都有谁
    var callRoomId = ""
    var callChatId = ""
    var callRoster: [GroupCallMember] = []
    /// 通话里的 SDP（WebRTC 协商用，字符串形式）
    var callSDP: String? = nil
    /// 语音「服务器转发」的一帧音频（base64 的 16kHz 单声道 PCM）
    var callAudioData: String? = nil
    /// 通话里的 ICE 候选（整段 JSON 字符串）
    var callCandidate: String? = nil
    /// 挂断原因：hangup / rejected / cancel / timeout / offline / disconnected
    var callReason = ""
    /// 有人在**新设备**上请求登录（登录确认）：6 位码 + 那台设备的名字。
    /// 收到就弹一条本地通知，点一下直接进「登录确认」卡片，不用手输数字。
    var pairCode = ""
    var pairDevice = ""
    /// 通话前问服务器「两端是不是同一个网络」的回答（同一个 → 直连，不同 → 强制走中继）
    var callSameNetwork = false
    /* ---- 直播专场（弹幕/点赞/在线人数） ---- */
    var roomId = ""
    var liveAction = ""
    var liveText = ""
    var liveFrom = ""
    var watching = 0
    var likes = 0
    /* 直播信令（真视频直播）：谁发的、什么类型、SDP/候选 */
    var liveFromId = ""
    var liveSigKind = ""
    var liveSDP = ""
    var liveCandidate = ""
    /// 拍一拍：谁拍的（patFrom）、拍的谁（patTo）
    var patFrom = ""
    var patTo = ""
    var tick = 0
    /// ready 里带回来：服务器上我这边还有没有一通"进行中"的电话
    /// （重连时用它校对本地通话页，避免"对方早挂了、我还显示着"）
    var callActive: Bool? = nil
}

/// 和服务器保持一条长连接（WebSocket）：别人一发消息，这边立刻就能收到，
/// 不用轮询。断了会自动重连。
/// 收包时间戳（带锁，跨线程读写安全）：收包循环在后台线程跑，心跳在主线程看它
final class RxClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date()
    func touch() { lock.lock(); t = Date(); lock.unlock() }
    var value: Date { lock.lock(); defer { lock.unlock() }; return t }
}

@MainActor
final class Realtime: ObservableObject {
    static let shared = Realtime()

    @Published private(set) var event = PushEvent()
    @Published private(set) var connected = false

    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var tick = 0
    /// 是否走明文通道、连着失败几次了（见 start() 里的说明）
    private var plainFallback = false

    /// 服务器是不是内网地址（192.168.x / 10.x / 172.16-31.x / 127.x / localhost）
    /// —— 只有内网才允许走 5180 明文口（服务器那边也只放行内网）
    static func isLanHost(_ host: String) -> Bool {
        let h = (host.split(separator: ":").first.map(String.init) ?? host).lowercased()
        if h == "localhost" || h == "127.0.0.1" || h == "::1" { return true }
        if h.hasPrefix("10.") || h.hasPrefix("192.168.") { return true }
        if h.hasPrefix("172.") {
            let second = Int(h.split(separator: ".").dropFirst().first.map(String.init) ?? "") ?? 0
            return second >= 16 && second <= 31
        }
        return false
    }
    private var failCount = 0
    /// 这条长连接是什么时候建起来的（判"活够久就算连上过"，见 onSocketDown）
    private var socketUpAt = Date()
    /// 推送洪水的节流：消息一秒钟来几千条时，不能每条都去通知界面（会把手机刷死）。
    /// 这里最多每 0.25 秒往界面发一次，攒着的那条在稍后合并发出去。
    private var pending: PushEvent?
    private var publishTask: Task<Void, Never>?
    /// 心跳：每 15 秒给服务器发一个 ping，35 秒收不到任何东西就认为断了、重连
    private var heartbeat: Task<Void, Never>?
    private let rxClock = RxClock()
    /* 投递回执：收到消息先攒着（chatId → 最大 seq），1.5 秒合并发一次。
       后台的「消息投递日志」靠它区分 未送达 / 已送达 / 已读（微信也是这么分的）。 */
    private var ackPending: [String: Int] = [:]
    private var ackTask: Task<Void, Never>?

    /// 收到某条消息 → 记一笔回执（攒着批量发，省流量）
    func ackDelivery(chatId: String, seq: Int) {
        guard !chatId.isEmpty, seq > 0 else { return }
        if let cur = ackPending[chatId], cur >= seq { return }
        ackPending[chatId] = seq
        if ackTask != nil { return }
        ackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self = self else { return }
            self.flushAcks()
            self.ackTask = nil
        }
    }

    private func flushAcks() {
        let batch = ackPending
        ackPending.removeAll()
        for (chatId, seq) in batch {
            sendJSON(["type": "ack", "chatId": chatId, "seq": seq])
        }
    }

    func start() {
        /* 已经在连着就别再重建 —— 以前每调一次 start() 都会先 stop() 再新建，
           而「回到前台 / 刷新」这些地方会调它，于是长连接被反复掐断重建
           （日志里那个号 10 分钟断 300 多次就是这么来的，消息也就跟着卡）。 */
        if socket != nil, connected { return }
        stop()
        guard !API.shared.token.isEmpty else { return }
        /* 服务器是加密口（5443，https/wss）。
           以前这里写死了 ws://host:5443 —— 拿明文去握加密口，服务器直接 socket hang up，
           于是实时推送一直是断的：聊天页不刷新、通话记录/转账状态也收不到。
           现在默认 wss（和网页版一样），万一这个部署只开了明文口，再退回 ws://host:5180。 */
        let host = API.shared.server
        /* 明文口（5180）已经在服务端关掉了：公网来的明文 ws 一律 403，
           所以这里只在「服务器是内网地址」时才允许退回明文（内网调试用），
           公网域名永远只走 wss —— 不然降级那一下，令牌和聊天内容就明着过网了。 */
        let plainHost = host.replacingOccurrences(of: ":5443", with: ":5180")
        let lanOnly = Self.isLanHost(host)
        let raw = (plainFallback && lanOnly) ? "ws://\(plainHost)" : "wss://\(host)"
        guard let url = URL(string: "\(raw)/?token=\(API.shared.token)") else { return }
        /* 带上版本号：服务器会把「主叫/被叫分别是哪个包」写进通话日志，
           排查「对端太旧所以云通话进不来」这种问题一眼就能看到。 */
        var req = URLRequest(url: url)
        req.setValue(AppInfo.build, forHTTPHeaderField: "X-App-Build")
        /* 端类型 + 设备标识：服务器「手机单点登录」要认这两样 ——
           新手机一登录，同一个账号还连着的旧手机就会被推一条 kick、长连接也连不上。 */
        req.setValue(AppInfo.deviceKind, forHTTPHeaderField: "X-Device-Kind")
        req.setValue(AppInfo.deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue(AppInfo.deviceModel, forHTTPHeaderField: "X-Device-Model")
        let task = API.shared.session.webSocketTask(with: req)
        socket = task
        socketUpAt = Date()
        task.resume()
        /* ⚠ 收包这个循环**故意不跑在主线程上**（Task.detached）：
           这个类是 @MainActor，以前循环就跟着主线程跑 —— 聊天页一卡几百毫秒
           （线上日志：卡顿 聊天页 最长 628ms），这个 await receive() 就被一起拖住，
           语音帧读不出来，声音就一顿一顿的（用户说的「语音又卡了」）。
           现在：循环在后台跑，语音帧在后台直接丢给播放器，只有别的业务事件
           才回主线程处理（updateRx / handle）。顺带一个好处：通话时每秒 25 帧
           不再去刷界面状态，主线程也轻了。 */
        let clock = rxClock          // 在主线程上取出来，交给后台那个循环用
        loop = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    var text = ""
                    switch message {
                    case .string(let t): text = t
                    case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default: break
                    }
                    if !text.isEmpty {
                        clock.touch()
                        /* 通话音频帧：在这里就地消费掉，绝不经过主线程 */
                        if Self.consumeCallAudioIfAny(text) { continue }
                        /* ⚠ 别的业务事件**丢给主线程异步处理，这里绝不等**：
                           主线程一卡（聊天页那种一两秒的停顿），一等就把后面排队的语音帧
                           全堵在 socket 里；等它回来时几十帧一起灌进来，声音就一顿一顿。
                           语音帧的实时性比"事件顺序"重要得多。 */
                        if let self = self {
                            let t = text          // 拷一份常量再进并发闭包（不然编译器不让）
                            Task { @MainActor in self.handle(t) }
                        }
                    } else {
                        clock.touch()
                    }
                } catch {
                    // 断了：3 秒后重连
                    if Task.isCancelled { break }
                    guard let self = self else { break }
                    await self.onSocketDown(lanOnly: lanOnly)
                    return
                }
            }
        }
        connected = true
        rxClock.touch()
        /* 心跳 + 假死检测：服务器半分钟没动静就重连一次（比一直挂着收不到消息强） */
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { return }
                guard let self = self else { return }
                if Date().timeIntervalSince(self.rxClock.value) > 35 {
                    self.connected = false
                    self.start()
                    return
                }
                self.sendJSON(["type": "ping"])
            }
        }
    }

    /* ---------------- 收包循环用的几个小工具（后台线程 / 主线程各自需要的部分） ---------------- */

    /// 通话音频帧：在后台**就地**丢给播放器，返回 true 表示这条已经处理掉了。
    /// 必须在主线程之外调用 —— 主线程一卡（聊天页卡顿几百毫秒），声音就跟着卡。
    private nonisolated static func consumeCallAudioIfAny(_ text: String) -> Bool {
        guard text.contains("\"audio\"") else { return false }        // 便宜的前置判断
        guard let d = text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (o["action"] as? String) == "audio",
              let b64 = o["data"] as? String,
              let ad = Data(base64Encoded: b64) else { return false }
        CallAudioPipe.shared.play(ad)
        return true
    }

    /// 长连接断了：置位 + 退避重连（要动主线程上的状态，所以单独拿出来）
    private func onSocketDown(lanOnly: Bool) async {
        connected = false
        AppLog.info("实时长连接断了（第 " + String(failCount + 1) + " 次），准备重连", net: true)
        /* ⚠ 2026-10-14：这条连接**活过 10 秒**就说明刚才那次是真的连上了（不是线路被掐），
           失败计数清零。以前这个计数只加不减，时间越久越容易触发"换线路"，
           一路换到备用入口（当时备用里有香港那台旧镜像）就再也回不来 ——
           表现就是用户说的「莫名其妙出现未连接」。 */
        if Date().timeIntervalSince(socketUpAt) > 10 { failCount = 0 }
        /* 连着失败 3 次就换另一种协议再试；但只有内网地址才会真的退到明文口
           （见 start() 里 lanOnly 那段）。 */
        failCount += 1
        if failCount % 3 == 0, lanOnly { plainFallback.toggle() }
        /* 连着断 3 次（差不多十几秒）：多半不是消息问题，是这条线路被掐了，
           自动换下一条备用入口再连（换通了以后所有请求都走新的那条）。 */
        if failCount % 3 == 0 { _ = API.shared.rotateEndpoint() }
        /* 退避重连：1s → 2s → 3s → 最长 15s，避免疯狂重连刷屏、刷服务器 */
        let wait = min(15.0, 1.0 + Double(failCount))
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        if Task.isCancelled { return }
        start()
    }

    /// 往长连接里发一条 JSON（通话信令用）
    func sendJSON(_ obj: [String: Any]) {
        guard let socket = socket,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var ev = PushEvent()
        ev.type = (obj["type"] as? String) ?? ""
        ev.chatId = (obj["chatId"] as? String) ?? ""
        if let m = obj["message"] as? [String: Any] {
            ev.fromId = (m["senderId"] as? String) ?? ""
            /* 消息推送里 chatId 是包在 message 里面的（顶层没有）——补上，
               聊天页/列表判断「这条是不是我正开着的会话」才准。 */
            if ev.chatId.isEmpty { ev.chatId = (m["chatId"] as? String) ?? "" }
            /* 收到推送就回执：这条已经到我手机上了 */
            if let cid = m["chatId"] as? String ?? obj["chatId"] as? String,
               let sq = (m["seq"] as? NSNumber)?.intValue {
                ackDelivery(chatId: cid, seq: sq)
            }
        }
        if let b = obj["balance"] as? Double { ev.balance = b }
        else if let b = obj["balance"] as? Int { ev.balance = Double(b) }
        // 资料变动（换封面 / 换头像 / 改昵称 / 改状态）：服务器推的是 profile
        if let u = obj["user"] as? [String: Any],
           let d = try? JSONSerialization.data(withJSONObject: u),
           let decoded = try? JSONDecoder().decode(User.self, from: d) {
            ev.user = decoded
        }
        ev.announce = (obj["text"] as? String) ?? ""
        /* 拍一拍：谁拍的、拍的谁（服务器单独推的一条轻量事件，给接收方一个"被拍了"的反馈） */
        ev.patFrom = (obj["userId"] as? String) ?? ""
        ev.patTo = (obj["targetId"] as? String) ?? ""
        /* 阅后即焚：服务端销毁了哪几条（ids 是服务端广播时带的字段） */
        if let ids = obj["ids"] as? [String] { ev.burnIds = ids }
        /* 群通话「谁在说话」：服务端每 250ms 广播一次整屋音量 */
        if let lv = obj["levels"] as? [String: Any] {
            var out: [String: Double] = [:]
            lv.forEach { k, v in if let n = v as? NSNumber { out[k] = n.doubleValue } }
            ev.callLevels = out
        }
        /* 设备确认登录：有人在新设备上点「微信登录」，服务器给已登录的这几台推过来。
           立刻弹一条本地通知（前台也弹），点通知就进「登录确认」卡片。 */
        ev.pairCode = (obj["pairCode"] as? String) ?? ""
        ev.pairDevice = (obj["pairDevice"] as? String) ?? ""
        if ev.type == "pair", !ev.pairCode.isEmpty {
            PushCenter.shared.showPairRequest(code: ev.pairCode, device: ev.pairDevice)
        }
        /* 手机在别处登录（手机单点登录）：服务器把旧设备顶下线，推这一条过来。
           立刻弹「你的账号在另一台设备上登录」卡片，并把实时连接停掉。 */
        if ev.type == "kick" {
            let dev = (obj["device"] as? String) ?? ""
            let at = (obj["at"] as? Double) ?? 0
            OtherLogin.shared.trigger(device: dev, atMillis: at)
        }
        if let ca = obj["callActive"] as? Bool { ev.callActive = ca }
        if let n = obj["momentUnread"] as? Int { ev.momentUnread = n }
        if let n = obj["momentNoticeUnread"] as? Int { ev.momentNoticeUnread = n }
        /* 朋友圈「消息列表」实时推过来的那一条（谁赞了/评论了我） */
        if let n = obj["notice"] as? [String: Any] { ev.momentNotice = MomentNotice(json: n) }
        if let n = obj["friendRequests"] as? Int { ev.friendRequests = n }
        ev.action = (obj["action"] as? String) ?? ""
        // 转账状态变化（对方收款 / 24 小时退回）
        if let t = obj["transfer"] as? [String: Any] {
            ev.transferFromId = (t["fromId"] as? String) ?? ""
            ev.transferStatus = (t["status"] as? String) ?? ""
            if let a = t["amount"] as? Double { ev.transferAmount = a }
            else if let a = t["amount"] as? Int { ev.transferAmount = Double(a) }
        }
        // 通话信令（invite/incoming/ringing/accept/reject/cancel/hangup）
        ev.callId = (obj["callId"] as? String) ?? ""
        ev.callAction = (obj["action"] as? String) ?? ""
        ev.callMedia = (obj["media"] as? String) ?? ""
        ev.callPeerId = (obj["peerId"] as? String) ?? ""
        ev.callPeerName = (obj["peerName"] as? String) ?? ""
        ev.callPeerAvatar = (obj["peerAvatar"] as? String) ?? ""
        ev.callError = (obj["error"] as? String) ?? ""
        ev.callPeerMuted = (obj["muted"] as? Bool) ?? false
        ev.callPeerCameraOff = (obj["camOff"] as? Bool) ?? false
        ev.callPeerVideo = (obj["video"] as? Bool) ?? false
        ev.callRoomId = (obj["roomId"] as? String) ?? ""
        ev.callChatId = (obj["chatId"] as? String) ?? ""
        if let arr = obj["roster"] as? [[String: Any]] {
            ev.callRoster = arr.map {
                GroupCallMember(userId: ($0["userId"] as? String) ?? "",
                                name: ($0["name"] as? String) ?? "",
                                avatar: ($0["avatar"] as? String) ?? "",
                                muted: ($0["muted"] as? Bool) ?? false)
            }
        }
        ev.callReason = (obj["reason"] as? String) ?? ""
        if let same = obj["same"] as? Bool { ev.callSameNetwork = same }
        // 直播：进的哪个房间、什么动作（弹幕/点赞/人数）、谁说的、多少人
        ev.roomId = (obj["roomId"] as? String) ?? ""
        ev.liveAction = (obj["action"] as? String) ?? ""
        ev.liveText = (obj["text"] as? String) ?? ""
        ev.liveFrom = (obj["from"] as? String) ?? ""
        if let w = obj["watching"] as? Int { ev.watching = w }
        if let l = obj["likes"] as? Int { ev.likes = l }
        ev.liveFromId = (obj["from"] as? String) ?? ""
        ev.liveSigKind = (obj["sigKind"] as? String) ?? ""
        if let sdp = obj["sdp"] as? [String: Any] { ev.liveSDP = (sdp["sdp"] as? String) ?? "" }
        if let cand = obj["candidate"] as? [String: Any],
           let d2 = try? JSONSerialization.data(withJSONObject: cand),
           let t2 = String(data: d2, encoding: .utf8) { ev.liveCandidate = t2 }
        // WebRTC 协商内容：SDP 和 ICE 候选（网页版也是这么传的）
        if let sdp = obj["sdp"] as? [String: Any] { ev.callSDP = (sdp["sdp"] as? String) ?? "" }
        if let audio = obj["data"] as? String, !audio.isEmpty { ev.callAudioData = audio }
        if let cand = obj["candidate"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: cand),
           let text = String(data: data, encoding: .utf8) {
            ev.callCandidate = text
        }
        /* 推送洪水节流：每条都通知界面的话，几千条一来手机就卡死/崩。
           有任务在跑就先攒着，最多每 0.25 秒发一次（最后那条一定会发出去）。 */
        /* ⚠ 好友申请 / 通话 / 转账 / 提示这类「低频但重要」的事件不能进节流队列 ——
           节流只留最后一条，窗口里再来一条普通消息就会把它顶掉，
           表现就是「好友点了添加，我这边没立刻刷新」。这类事件一律立刻推。 */
        let important = ["friend", "call", "transfer", "transferRemind", "toast", "moment", "profile", "pair"]
        if important.contains(ev.type) {
            pending = nil                 // 重要事件优先，顺手清掉排队里那条（免得稍后又闪一下）
            tick += 1
            ev.tick = tick
            event = ev
            return
        }
        if publishTask == nil {
            tick += 1
            ev.tick = tick
            event = ev
            publishTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self = self, !Task.isCancelled else { return }
                self.publishTask = nil
                if let p = self.pending {
                    self.pending = nil
                    self.tick += 1
                    var merged = p
                    merged.tick = self.tick
                    self.event = merged
                }
            }
        } else {
            pending = ev
        }
    }
}

