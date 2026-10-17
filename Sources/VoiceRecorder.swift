import Foundation
import AVFoundation
import Combine
import UIKit

/* ============================================================
   按住说话（语音消息）
     · 按住麦克风开始录音（m4a / AAC，16k 单声道，够清楚又不占流量）
     · 手指上滑 60pt 取消；松手发送
     · 录完上传到服务器的 /uploads，再发一条 kind=audio 的消息
   点一下语音气泡就能播放（VoicePlayer）。
   ============================================================ */

@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    static let shared = VoiceRecorder()

    @Published private(set) var recording = false
    @Published private(set) var seconds = 0
    @Published private(set) var level: CGFloat = 0        // 0…1，界面画音量
    @Published private(set) var willCancel = false
    /// 上滑到「滑到这里 转文字」那一档（松手后把这段语音转成文字，微信就是这个手势）
    @Published private(set) var willTranscribe = false
    /// 微信的按住说话最长 60 秒，到点自动发出
    let maxSeconds = 60

    private var rec: AVAudioRecorder?
    private var ticker: Timer?
    private var fileURL: URL?
    private var startedAt = Date()
    /// 音量的平滑值（涨得快、落得慢）—— 球的起伏用它，不用原始值，
    /// 否则每 60ms 一跳，看着是"抖"不是"跟着说话变"
    private var ampSmooth: Double = 0
    /// 阻尼振动反馈：开始录音一下（中等）、滑到"转文字/取消"各一下（轻）、发送一下（轻）
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private let hapticLight = UIImpactFeedbackGenerator(style: .light)

    private override init() { super.init() }

    /// 按住：开始录（会先要麦克风权限）
    func begin() async -> Bool {
        guard !recording else { return true }
        guard await Permission.ask(.audio) else { return false }

        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default,
                           options: [.defaultToSpeaker, .allowBluetooth])
        try? s.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(Int(Date().timeIntervalSince1970 * 1000)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        r.isMeteringEnabled = true
        r.record()
        rec = r
        fileURL = url
        startedAt = Date()
        seconds = 0
        level = 0
        willCancel = false
        recording = true
        /* 开始录音：中等强度的"咔"一下（微信按住说话也是先震一下再出那颗球） */
        haptic.prepare()
        haptic.impactOccurred()
        ticker?.invalidate()
        /* 音量采样 0.06 秒一次（原来是 0.1）：Siri 那颗球的"互动"要跟得上说话，
           采样太慢球就像在慢慢缩放，看不出跟声音走 */
        ticker = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in self.tick() }
        }
        return true
    }

    private func tick() {
        guard let r = rec else { return }
        seconds = Int(Date().timeIntervalSince(startedAt))

        /* 看门狗：录音超过「最长时长 + 2 秒」还在录，说明有手势没走到 end()
           （切页、来电、界面被系统打断都会这样）。直接收摊 —— 不然那颗球
           会一直挂在聊天页上（用户反馈的"刷新完还在页面上"）。 */
        if Date().timeIntervalSince(startedAt) > Double(maxSeconds) + 2 {
            CrashCatcher.note("录音", "看门狗触发：超过 \(maxSeconds + 2) 秒还在录，强制结束")
            _ = end()
            return
        }

        r.updateMeters()
        let db = r.averagePower(forChannel: 0)          // -160…0
        let raw = Double(max(0.0, min(1, (db + 55) / 55)))
        /* 平滑：**涨得快、落得慢**（和 Siri 那套一样）——
           一出声球马上跟着胀起来，停声之后慢慢收回去，
           中间不会一跳一跳的。系数后台可调：voiceOrbAttack / voiceOrbRelease。 */
        let attack = Double(UIConfig.num("voiceOrbAttack", 0.55))
        let release = Double(UIConfig.num("voiceOrbRelease", 0.16))
        ampSmooth += (raw - ampSmooth) * (raw > ampSmooth ? attack : release)
        level = CGFloat(max(0.04, min(1, ampSmooth)))
    }

    /// 这次录音是不是"孤儿"：已经开始很久（超过最长时长 + 2 秒）却还没停。
    /// 说明松手那一下没走到 end()（切页、来电、被打断），聊天页进来要把它收掉。
    var stale: Bool {
        recording && Date().timeIntervalSince(startedAt) > Double(maxSeconds) + 2
    }

    /// 强制收摊：把录音停掉、状态复位（聊天页进来发现孤儿录音时用）
    func forceStop() {
        guard recording else { return }
        rec?.stop()
        rec = nil
        ticker?.invalidate()
        ticker = nil
        recording = false
        seconds = 0
        level = 0
        ampSmooth = 0
        willCancel = false
        willTranscribe = false
    }

    /// 手指上滑就准备取消
    /// 上滑分两档（照微信那张图）：先进入「转文字」，再往上滑才取消
    func drag(_ dy: CGFloat) {
        let t = dy < -60 && dy > -140
        let c = dy <= -140
        /* 滑过档位就轻震一下（阻尼感）—— 只在**状态真的变了**的时候震，
           不然手指抖一下会连着震好几下。 */
        if t != willTranscribe || c != willCancel {
            hapticLight.impactOccurred()
        }
        willTranscribe = t
        willCancel = c
    }

    /// 松手：返回要发的文件；取消 / 时间太短返回 nil
    func end() -> (url: URL, seconds: Int)? {
        guard let r = rec, let url = fileURL else {
            recording = false
            return nil
        }
        let secs = Int(Date().timeIntervalSince(startedAt).rounded())
        let cancelled = willCancel || secs < 1
        r.stop()
        rec = nil
        ticker?.invalidate()
        ticker = nil
        recording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if cancelled {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        hapticLight.impactOccurred()      // 松手发出去：轻震一下
        return (url, max(1, secs))
    }

    func cancel() {
        willCancel = true
        _ = end()
    }
}

/* ---------------------------------------------------------- 播放 */

@MainActor
final class VoicePlayer: NSObject, ObservableObject {
    static let shared = VoicePlayer()

    /// 正在播哪条（消息 id），界面拿它显示播放状态
    @Published private(set) var playingID = ""
    /// 这一条的播放进度（0~1）：气泡里那根可以拖的进度条要用
    @Published private(set) var progress: Double = 0
    /// 已经播了多少秒 / 这条一共多少秒（拖动时气泡上显示「0:05 / 0:12」）
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var total: Double = 0
    /// 语音倍速：1x / 2x（用户要求「要可以 x1 x2」）。存本机，下次打开还是这个速度。
    @Published private(set) var rate: Float = VoicePlayer.savedRate

    static var savedRate: Float {
        UserDefaults.standard.double(forKey: "chris.voiceRate") > 1.5 ? 2 : 1
    }

    /// 1x ⇄ 2x：正在播的话立刻变速，不用从头上重播
    func toggleRate() {
        rate = rate > 1.5 ? 1 : 2
        UserDefaults.standard.set(Double(rate), forKey: "chris.voiceRate")
        applyRate()
    }

    /// 把速度套到播放器上（AVAudioPlayer **必须先开 enableRate** 才认 rate）
    private func applyRate() {
        guard let p = player else { return }
        p.enableRate = true
        p.rate = rate
    }

    private var player: AVAudioPlayer?
    /// 已经下载过的那几条语音（免得每点一次都重新下）
    private var cache: [String: Data] = [:]
    /// 进度条 0.1 秒跳一次
    private var ticker: Timer?
    /// 播放器还没准备好时用户就先拖了：记住要跳到的位置，等能播了再跳
    private var pendingFraction: Double?

    private override init() { super.init() }

    func toggle(id: String, url: URL) {
        if playingID == id { stop(); return }
        stop()
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)
        try? s.setActive(true)
        playingID = id
        /* 语音文件在服务器上（/uploads/xxx.m4a）：
           以前这里直接 AVAudioPlayer(contentsOf: 网络地址) —— 它只认本地文件，
           所以点了一点声音都没有。现在先带登录令牌把文件下下来，再用 data 播。 */
        let key = url.absoluteString
        if let hit = cache[key], let p = try? AVAudioPlayer(data: hit) {
            p.delegate = self
            p.prepareToPlay()
            p.enableRate = true
            p.rate = rate
            applyPending(to: p)
            p.play()
            player = p
            startTicker()
            return
        }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let data = try await API.shared.assetData(url)
                guard !data.isEmpty else { self.playingID = ""; return }
                self.cache[key] = data
                if self.cache.count > 24 { self.cache.removeValue(forKey: self.cache.keys.first ?? "") }
                /* 下载期间用户可能已经点了别的/点了停 */
                guard self.playingID == id else { return }
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                p.prepareToPlay()
                p.enableRate = true
                p.rate = self.rate
                self.applyPending(to: p)
                p.play()
                self.player = p
                self.startTicker()
            } catch {
                self.playingID = ""
            }
        }
    }

    /// 拖动进度条：fraction 是 0~1。播放器还没起来就先把位置记着，
    /// 等下好了直接从那儿开始（用户的感觉是「一拖就跳过去了」）。
    func seek(to fraction: Double) {
        let f = min(1, max(0, fraction))
        guard let p = player else {
            pendingFraction = f
            progress = f
            if total > 0 { elapsed = total * f }
            return
        }
        let d = max(0.01, p.duration)
        p.currentTime = d * f
        progress = f
        elapsed = p.currentTime
    }

    private func applyPending(to p: AVAudioPlayer) {
        total = p.duration
        if let f = pendingFraction {
            p.currentTime = max(0.01, p.duration) * f
            progress = f
            elapsed = p.currentTime
            pendingFraction = nil
        } else {
            progress = 0
            elapsed = 0
        }
    }

    private func startTicker() {
        ticker?.invalidate()
        /* 定时器闭包里**不捕获 self**：Swift 的并发检查不允许在嵌套的 Task 里
           引用被捕获的 var self（编译报 "reference to captured var 'self'"）。
           这里直接打那个单例 —— 它就是自己，而且一直活着。 */
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in VoicePlayer.shared.syncProgress() }
        }
    }

    func syncProgress() {
        guard let p = player else { return }
        total = p.duration
        elapsed = p.currentTime
        progress = p.duration > 0 ? min(1, max(0, p.currentTime / p.duration)) : 0
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        player?.stop()
        player = nil
        playingID = ""
        progress = 0
        elapsed = 0
        pendingFraction = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension VoicePlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}
