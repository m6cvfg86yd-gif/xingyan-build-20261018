import Foundation
import AVFoundation
import CoreMedia
import UIKit

/* ============================================================
   语音通话的「服务器转发」通道（兜底方案）
   为什么要有它：有些运营商（比如中国移动 4G）把到 TURN 服务器的通道全挡了，
   手机连一个中继候选都拿不到，WebRTC 就永远接不通。
   这条路走 App 一直在用的那条 WebSocket（wss/443），运营商挡不住：
     · 麦克风 → 16kHz 单声道 PCM → 40 毫秒一帧 → base64 → 长连接发出去
     · 收到对方的帧 → 直接丢给播放器
   服务端只是原样转发（action: 'audio'），1 帧 1280 字节，够小。
   ============================================================ */
final class CallAudioPipe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = CallAudioPipe()

    /// 本机麦克风最近的音量（0…1，按峰值归一）：群通话「谁在说话」上报用（2026-10-13）
    private(set) var lastLevel: Double = 0
    /// 发出去那一帧的序号（2 字节，循环）
    private var outSeq: UInt16 = 0
    /// 收到的那一帧序号（期望值）：用来判丢帧/乱序
    private var expectSeq: UInt16? = nil
    /// 丢帧补出来的帧数（PLC）、乱序丢掉的数量（都写进通话诊断）
    private(set) var plcFilled = 0
    private(set) var outOfOrder = 0
    /// 抖动缓冲目标深度（帧数，40ms 一帧）：网络抖就自动加厚，稳了再慢慢放薄
    /* ⚠ 2026-10-14：默认垫子 4 帧（约 160ms）不够 —— 实测到达间隔最大到 4.1 秒，
       一积压就丢帧（收到 4893 只播 2447）。默认加到 6 帧，上限放到 12 帧（约 480ms）。 */
    private var bufferTarget: Int = 4
    private var lastPlcAt: Date = .distantPast
    /// 上一帧的音频（PLC 补帧用）
    private var lastPlayedFrame: Data? = nil
    /// 每帧多少采样（16000Hz × 0.04s = 640）
    private let sampleRate: Double = 16000
    private let frameSamples = 640

    /* 采集用 AVCaptureSession（录视频那套音频管线）：
       它自己管音频会话，不像 AVAudioEngine.inputNode 那样容易被会话状态卡住
       —— 之前「engine 起不来」就是栽在这儿。 */
    private let capture = AVCaptureSession()
    private let audioOut = AVCaptureAudioDataOutput()
    private let captureQueue = DispatchQueue(label: "chris.call.capture")

    /* 播放单独一个「只挂播放器」的引擎：不带输入，一定起得来 */
    private let player = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var playerReady = false
    /// 引擎的节点只 attach/connect 一次（重复 attach 会抛异常）
    private var wired = false
    /// 播放相关的操作都在这条串行队列上做（自愈重启可能 sleep 一下，不能堵主线程）
    private let playQueue = DispatchQueue(label: "chris.call.play")
    /// 播放端看门狗：引擎被系统/别的 App 掐停之后 2 秒内拉回来
    private var watchdog: DispatchSourceTimer?

    /* 播放端统计（诊断用）：「两边都在发帧、却听不到声音」这种问题，
       以前日志里只有「采集=ok」，根本看不出是哪一头不响。 */
    private(set) var framesIn = 0            // 服务器转过来的帧
    private(set) var framesScheduled = 0     // 真的排进播放器的帧
    private(set) var framesDropped = 0       // 播放器没起来时丢掉的帧
    /// 采到并**发出去**多少帧（诊断用）：能一眼分清
    /// 「采集=ok 但一帧都没采到」（假通、对面听不见我）和「我这边根本没在采」
    private(set) var framesOut = 0

    /* 采集端的自愈（单向没声音的正解）：
       播放端一直有看门狗，采集端以前**没有** —— 来电打断、切后台回来、
       插拔蓝牙耳机之后，系统会把音频会话置成未激活、AVCaptureSession 也不再回调，
       可是 `capture.isRunning` 还标着 true。于是：我听得见对方（播放端被看门狗拉回来了），
       对方听不见我（采集端没人管）—— 这就是用户报的「单向没声音」。 */
    private var repairing = false
    private let repairQueue = DispatchQueue(label: "chris.call.repair")
    private var observers: [NSObjectProtocol] = []

    /* 抖动/延迟守卫：pendingFrames = 还没排进播放器的帧；
       queuedUntil = 播放器里已经排到的时间点（40ms 一帧，纯时间推算，不靠 completion 回调 ——
       回调漏一次就会算错，上一版就是被这个拖成"排播比收到少一大截"，声音一顿一顿）。 */
    private var pendingFrames: [Data] = []
    private var queuedUntil = Date.distantPast
    /// 这一通里排得最长的一次延迟（>1.5 秒就会被丢帧压回来），上报出来看得见
    private var latencyPeak = 0.0
    /* 电平表（2026-10-12 加）：光看「收到/排播多少帧」分不出**采到的是不是静音**、
       **播出去的到底有没有声** —— 用户报的「都在通话中但一个字听不见」就是这种。
       这里记最近一帧的峰值（Int16，0 = 完全静音），写进通话结束那条上报里。 */
    private var lastCapturePeak = 0
    private var lastPlayPeak = 0
    /// 采集端「不出帧」被自动重抢了几次（用户报的「一会会我的声音没了、对方还在」）
    private(set) var captureStalls = 0
    /// 最近一帧用的软件增益（诊断用：太大说明输入太小）
    private var lastCaptureGain = 1.0

    /// 通话结束时上报给服务器，写进 call-trace.log
    var playDiag: String {
        "播放端 收到=\(framesIn) 排播=\(framesScheduled) 丢=\(framesDropped)"
            + " 采集端 发出=\(framesOut)帧"
            /* 2026-10-13：抖动缓冲 / 丢包补偿的实况（排查"断续/杂音"看这几个数就够了） */
            + " 补帧=\(plcFilled) 乱序=\(outOfOrder) 缓冲=\(bufferTarget)帧"
            + " 延迟峰值=\(String(format: "%.1f", latencyPeak))s"
            + " 引擎=\(player.isRunning ? "跑" : "停")"
            + " 播放器=\(playerReady ? (playerNode.isPlaying ? "跑" : "停") : "没起")"
            + " 采集电平=\(lastCapturePeak) 播放电平=\(lastPlayPeak)"
            + " 采集增益=\(String(format: "%.1f", lastCaptureGain))"
            + " 重抢麦=\(captureStalls)次"
    }

    /// 一段 16-bit 小端 PCM 的峰值（0 = 静音）
    private func peakOfInt16(_ data: Data) -> Int {
        var mx = 0
        let bytes = [UInt8](data)
        var i = 0
        while i + 1 < bytes.count {
            let raw = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            let a = abs(Int(Int16(bitPattern: raw)))
            if a > mx { mx = a }
            i += 2
        }
        return mx
    }

    private var started = false
    /// 抢麦克风的重试任务（上一通刚结束、TRTC/铃声还占着的时候要靠它抢回来）
    private var startTask: Task<Void, Never>?
    /// 已经交给 TRTC 了：本通道彻底闭嘴 —— 连「重试抢麦」都不许再跑。
    /// 少了这个标志，切给腾讯之后这边还在抢麦克风，腾讯开了麦却采不到音，
    /// 表现就是「切到 TRTC 了、两边反而都没声音」（线上真出过）。
    private var handedOver = false
    /// 采集有没有真的跑起来（起不来时页面/日志能看到原因）
    var isRunning: Bool { started && capture.isRunning }
    /// 起不来时的原因（上报日志用）
    private(set) var lastError = ""
    private var pending = Data()                 // 攒够一帧再发

    /// 采到一帧就回调（交给长连接发出去）
    var onFrame: ((Data) -> Void)?
    /// 采集**真正**起来（或彻底失败）之后回调一次：
    /// 以前是 start() 一返回就去看 isRunning，那时候异步的 startRunning 还没跑完，
    /// 日志里就会写「采集=失败 原因:（空）」这种误报。
    var onStateChange: ((Bool) -> Void)?

    private var playFormat: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)
    }

    func start() {
        if handedOver { return }        // 麦克风已经交给 TRTC，别再去抢
        if started { return }
        startTask?.cancel()
        started = false
        lastError = ""
        pending.removeAll()
        framesIn = 0
        framesScheduled = 0
        framesDropped = 0
        framesOut = 0
        queuedUntil = Date.distantPast
        latencyPeak = 0
        pendingFrames.removeAll()
        startWatchdog()
        observeSessionEvents()

        /* 麦克风经常被「上一通电话 / TRTC 进房 / 铃声引擎」占着，一次抢不到就报错的话，
           整通电话对面就听不到你说话（假通）。这里改成最多抢 6 次、每次间隔 0.7 秒，
           中间把音频会话放开再抢。 */
        startTask = Task.detached { [weak self] in
            guard let self = self else { return }
            for attempt in 0..<6 {
                if Task.isCancelled || self.started || self.handedOver { return }
                self.configureSession()
                self.startPlayback()
                if self.startCaptureBlocking() {
                    self.started = true
                    self.lastError = ""
                    /* 抢麦中间可能把音频会话关过（setActive(false)）——
                       系统会顺手把播放引擎掐停，而以前播放端只建一次，
                       引擎一死整通电话就一个字都听不见（服务器那边看帧数还正常）。
                       这里每次抢到麦克风后再确认一次播放端是活的。 */
                    self.startPlayback()
                    DispatchQueue.main.async { self.onStateChange?(true) }
                    return
                }
                /* 没抢到：放开音频会话，等一下再抢 */
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { return }
            }
            self.started = false
            DispatchQueue.main.async { self.onStateChange?(false) }
        }
    }

    func stop() {
        started = false
        startTask?.cancel()
        startTask = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        watchdog?.cancel()
        watchdog = nil
        captureQueue.async { [capture] in if capture.isRunning { capture.stopRunning() } }
        playQueue.sync {
            playerNode.stop()
            player.stop()
            playerReady = false
            queuedUntil = Date.distantPast
            pendingFrames.removeAll()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 把麦克风交给 TRTC：先停采集，并禁止后续任何重试抢麦
    func handOverToTRTC() {
        handedOver = true
        onFrame = nil
        stop()
    }

    /// 新的一通电话：复位「已交出」状态，让本通道可以再用
    func resetHandOver() { handedOver = false }

    /* ---------------------------------------------------------- 播放：只挂播放器的引擎 */

    /// 看门狗：通话期间每 2 秒看一眼播放引擎，停了就拉起来
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: playQueue)
        t.schedule(deadline: .now() + 1.5, repeating: 2.0)
        /* 「一会儿我这边就没声了、对方还在」= 采集还标着 running，其实已经不出帧了。
           老看门狗只看 capture.isRunning，这种情况它看不出来 ——
           这里盯 framesOut：连着两拍（≈4 秒）一帧没多，就**强制重抢麦克风**。
           （自己静音时采集照样出帧，所以不会误判。） */
        var lastOut = -1
        var stalledTicks = 0
        t.setEventHandler { [weak self] in
            guard let self = self, self.started, !self.handedOver else { return }
            self.startPlaybackOnQueue()
            /* 采集端也要盯：系统把采集掐停了（打断 / 路由变化）却没人管的话，
               就是「我听得见对面、对面听不见我」。 */
            if !self.capture.isRunning {
                self.repairNow()
                return
            }
            if self.framesOut == lastOut {
                stalledTicks += 1
                if stalledTicks >= 2 {
                    stalledTicks = 0
                    self.captureStalls += 1
                    self.lastError = "采集不出帧，已自动重抢麦克风"
                    self.repairNow(force: true)
                }
            } else {
                stalledTicks = 0
                lastOut = self.framesOut
            }
        }
        watchdog = t
        t.resume()
    }

    /// 盯住音频会话：来电打断结束、切后台回来、插拔蓝牙耳机之后，
    /// 系统会把会话置成未激活、采集一起停掉 —— 这时候必须重新激活 + 重启采集。
    private func observeSessionEvents() {
        guard observers.isEmpty else { return }
        let c = NotificationCenter.default
        observers.append(c.addObserver(forName: AVAudioSession.interruptionNotification,
                                       object: nil, queue: nil) { [weak self] note in
            guard let self = self else { return }
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            if raw == AVAudioSession.InterruptionType.began.rawValue { return }   // 等它结束再抢
            self.repairNow(force: true)
        })
        observers.append(c.addObserver(forName: AVAudioSession.routeChangeNotification,
                                       object: nil, queue: nil) { [weak self] _ in
            /* 插拔耳机 / 切外放 / 蓝牙连断：路由一变，采集经常就停了 */
            self?.repairNow(force: true)
        })
        observers.append(c.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                       object: nil, queue: nil) { [weak self] _ in
            /* 从后台回来：会话要重新激活，采集也要重新起来 */
            self?.repairNow(force: true)
        })
    }

    /// 修一把采集 + 播放（幂等；`force` = 就算 capture.isRunning 也真的重来一遍）。
    /// 全程在 repairQueue 上做，绝不占播放队列、也绝不占主线程。
    private func repairNow(force: Bool = false) {
        guard started, !handedOver, !repairing else { return }
        repairing = true
        repairQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.repairing = false }
            guard self.started, !self.handedOver else { return }
            self.configureSession()
            if force {
                /* 会话虽然还标着 running，其实已经不出声了 —— 必须真的停掉重开 */
                self.captureQueue.sync { if self.capture.isRunning { self.capture.stopRunning() } }
            }
            if force || !self.capture.isRunning {
                _ = self.startCaptureBlocking()
            }
            self.startPlayback()
            if self.capture.isRunning { DispatchQueue.main.async { self.onStateChange?(true) } }
        }
    }

    /// 对外入口（比如用户刚在设置里打开麦克风权限）：立刻重新抢一次麦
    func repairAudioNow() { repairNow(force: true) }

    /// 从任意线程调用：把播放引擎搭好 / 拉起来（幂等）
    private func startPlayback() {
        playQueue.sync { startPlaybackOnQueue() }
    }

    private func startPlaybackOnQueue() {
        guard let fmt = playFormat else { return }
        if !wired {
            player.attach(playerNode)
            player.connect(playerNode, to: player.mainMixerNode, format: fmt)
            wired = true
        }
        /* 已经在跑就别折腾（这个函数会被看门狗、每帧播放反复调到） */
        if playerReady, player.isRunning, playerNode.isPlaying { return }
        _ = try? AVAudioSession.sharedInstance().setActive(true, options: [])
        player.prepare()
        for attempt in 0..<4 {
            if playerReady, player.isRunning, playerNode.isPlaying { return }
            do {
                if !player.isRunning { try player.start() }
                playerNode.play()
                if player.isRunning {
                    playerReady = true
                    return
                }
            } catch {
                lastError = (lastError.isEmpty ? "" : lastError + " / ") + "播放引擎: \(error.localizedDescription)"
            }
            if attempt < 3 { Thread.sleep(forTimeInterval: 0.25) }
        }
        /* 4 次都没起来：明说「播放端没起来」，别让日志继续只报「采集=ok」 */
        playerReady = false
        if !lastError.contains("播放引擎没起来") {
            lastError = (lastError.isEmpty ? "" : lastError + " / ") + "播放引擎没起来"
        }
    }

    /* ---------------------------------------------------------- 采集：AVCaptureSession */

    /// 配音频会话：每一轮抢麦之前都重新配一遍（上一通电话可能把它改过）
    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            /* ⚠ 这里**不能用 .voiceChat 模式**（2026-10-12 定位到的「听不见」根因）：
               .voiceChat 会打开系统的声学处理单元（VoiceProcessingIO），它和我们的
               AVCaptureSession 音频输入抢同一个输入设备 —— 表现就是采集回调照常来、
               帧照常发（采集端 发出=124帧），但采出来的 PCM **几乎是静音**
               （通话上报里「采集电平=17」，满量程 32767）。
               两边都在发帧、都在排播、都听不见，就是这么来的。
               换成 .default（不做声学处理）之后输入电平就正常了；代价是没有系统级回声消除，
               所以外面再加一层软件增益 + 限幅（见 captureOutput）。 */
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
        } catch {
            lastError = "setCategory 失败: \(error.localizedDescription)"
        }
        do { try session.setActive(true, options: []) } catch {
            lastError = (lastError.isEmpty ? "" : lastError + " / ") + "setActive 失败: \(error.localizedDescription)"
        }
    }

    /// 配好采集并启动；这一轮没起来就返回 false（调用方会放开会话、过一会儿重试）
    private func startCaptureBlocking() -> Bool {
        /* ⚠⚠ 这里**必须**全部串行在同一条 captureQueue 上做完。
           AVFoundation 有硬约束：beginConfiguration / commitConfiguration 之间**不允许**调
           startRunning，否则直接抛
             NSGenericException: -[AVCaptureSession startRunning] startRunning may not be
             called between calls to beginConfiguration and commitConfiguration
           然后 abort（signal 6）—— 这就是线上真崩过的那条
           （服务器 data/client-errors.jsonl 里 B578 那条、以及 B309 的 coreaudio tap 同类）。

           以前是「配置在调用线程做、startRunning 丢给 captureQueue 异步执行」，
           而抢麦会重试最多 6 轮、通话中途还有修复/打断恢复也会再抢一次 ——
           两个线程一交错，上一轮的 startRunning 还没跑完，这一轮就 beginConfiguration 了，
           于是就抛异常闪退。

           现在整段放进 captureQueue.sync：同一时刻只可能有一个线程在动这个会话，
           永远不可能交错。（调用方都是后台线程：detached 的抢麦任务 / repairQueue，
           不会卡主线程。） */
        var ok = false
        captureQueue.sync {
            if capture.isRunning { ok = true; return }
            capture.beginConfiguration()
            if capture.canSetSessionPreset(.high) { capture.sessionPreset = .high }
            if capture.inputs.isEmpty {
                guard let dev = AVCaptureDevice.default(for: .audio) else {
                    capture.commitConfiguration()
                    lastError = "找不到麦克风设备"
                    return
                }
                guard let input = try? AVCaptureDeviceInput(device: dev), capture.canAddInput(input) else {
                    capture.commitConfiguration()
                    /* 权限状态写清楚：日志里一眼能看出是「没授权」还是「被别人占着」 */
                    let st = AVCaptureDevice.authorizationStatus(for: .audio)
                    lastError = st == .denied ? "麦克风权限被拒绝（去 设置→本 App→麦克风 打开）"
                        : (st == .notDetermined ? "麦克风权限还没授予（弹窗还没点）"
                           : "拿不到麦克风输入（可能被上一通/别的引擎占着）")
                    return
                }
                capture.addInput(input)
            }
            if capture.outputs.isEmpty {
                if capture.canAddOutput(audioOut) { capture.addOutput(audioOut) }
                audioOut.setSampleBufferDelegate(self, queue: captureQueue)
            }
            capture.commitConfiguration()
            if !capture.isRunning { capture.startRunning() }
            ok = capture.isRunning
        }
        if !ok { lastError = "AVCaptureSession 没能启动" }
        return ok
    }

    /// 采集回调：CMSampleBuffer → 16kHz 单声道 Int16 → 攒够 40ms 发一帧
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return }
        var streamDesc = asbd.pointee
        guard let inFormat = AVAudioFormat(streamDescription: &streamDesc),
              let target = playFormat,
              let converter = AVAudioConverter(from: inFormat, to: target) else { return }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return }
        inBuf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0,
                                                          frameCount: Int32(frames),
                                                          into: inBuf.mutableAudioBufferList) == noErr else { return }
        let outCap = AVAudioFrameCount(Double(frames) * target.sampleRate / inFormat.sampleRate + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }
        var done = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if done { status.pointee = .noDataNow; return nil }
            done = true
            status.pointee = .haveData
            return inBuf
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let chunk0 = Data(bytes: ch[0], count: Int(out.frameLength) * 2)
        let peak = peakOfInt16(chunk0)
        lastCapturePeak = peak
        /* 顺手把电平归一成 0…1 存下来（群通话「谁在说话」上报给服务器）：
           满量程 32767，按 0.35 满量程算"在说话"，超过就算 1。 */
        lastLevel = max(0, min(1, Double(peak) / (32767.0 * 0.35)))
        /* 软件增益（简易 AGC）：输入偏小的时候提一把，太响的时候压一下 ——
           .default 模式下没有系统 AGC，不补一下对面听着还是很小。
           目标峰值约 6000（满量程的 18%），增益限在 0.5~6 倍之间；只对小于 4000 的做提升，
           避免把已经很响的声音再放大到削波。 */
        var out0 = chunk0
        if peak > 0, peak < 4000 {
            /* ⚠ 2026-10-14：上限原来是 6.0 —— 实测某台手机采集电平只有 233，
               6000/233 = 25.7，被 6.0 卡住 → 输出电平只有 ~1400，对方几乎听不到。
               把上限提到 30.0，安静麦克风也能被拉到目标电平（6000）。 */
            let gain = min(6.0, max(0.5, 6000.0 / Double(peak)))
            lastCaptureGain = gain
            if gain > 1.05 {
                var bytes = [UInt8](chunk0)
                var i = 0
                while i + 1 < bytes.count {
                    let raw = Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
                    let v = Int(Double(raw) * gain)
                    let clamped = Int16(max(-32768, min(32767, v)))
                    let u = UInt16(bitPattern: clamped)
                    bytes[i] = UInt8(u & 0xff)
                    bytes[i + 1] = UInt8((u >> 8) & 0xff)
                    i += 2
                }
                out0 = Data(bytes)
            }
        }
        pending.append(out0)
        let frameBytes = frameSamples * 2
        while pending.count >= frameBytes {
            let chunk = pending.prefix(frameBytes)
            pending.removeFirst(frameBytes)
            framesOut += 1
            /* ⚠ 2026-10-13 音质对齐微信：每帧前面加 **2 字节序号**（大端）。
               接收端靠它判断「有没有丢帧 / 乱序」，丢了就补一帧（PLC），
               而不是让播放器直接空过去 —— 空过去听着就是"咔哒/断续"。
               老版本（不带头）发过来的帧是正好 1280 字节，接收端按长度自动兼容。 */
            outSeq = (outSeq &+ 1) & 0xFFFF
            var frame = Data()
            frame.append(UInt8((outSeq >> 8) & 0xFF))
            frame.append(UInt8(outSeq & 0xFF))
            frame.append(Data(chunk))
            onFrame?(frame)
        }
    }

    /// 播放对方传来的一帧（16kHz 单声道 Int16）
    func play(_ data: Data) {
        guard !data.isEmpty else { return }
        framesIn += 1
        /* ⚠ 2026-10-13 音质对齐微信（抖动缓冲 + 丢包补偿）：
           · 带 2 字节序号的新帧（长度 = 1280 + 2）：按序号判丢帧/乱序
             —— 丢了的帧补一帧（把上一帧衰减着重复一遍，PLC），听感上不会有"咔哒"；
             · 不带序号的老帧（长度正好 1280）：原样播，行为和老版本一致。
           序号连续时什么都不做；明显乱序（迟到）的直接丢，避免顺序错乱。 */
        var payload = data
        if data.count == frameSamples * 2 + 2 {
            let hi = UInt16(data[data.startIndex])
            let lo = UInt16(data[data.startIndex + 1])
            let seq = (hi << 8) | lo
            payload = data.subdata(in: (data.startIndex + 2)..<data.endIndex)
            if let exp = expectSeq {
                let diff = Int((seq &- exp) & 0xFFFF)
                if diff == 0 || diff > 0x8000 {
                    /* 重复帧 / 迟到很久的旧帧：丢掉（不然声音会来回跳） */
                    if diff == 0 || diff < 0x8000 { outOfOrder += 1 }
                    return
                }
                if diff > 1 && diff < 20 {
                    /* 中间丢了 diff-1 帧 → 用上一帧衰减着补上（PLC） */
                    if let last = lastPlayedFrame {
                        let fill = min(diff - 1, 6)
                        for k in 0..<fill {
                            let att: Double = max(0.15, 0.55 - 0.08 * Double(k))
                            pendingFrames.append(attenuate(last, att))
                            plcFilled += 1
                        }
                    }
                    lastPlcAt = Date()
                    bufferTarget = min(6, bufferTarget + 1)    // 网络在抖 → 缓冲加厚
                }
            }
            expectSeq = (seq &+ 1) & 0xFFFF
            lastPlayedFrame = payload
        } else {
            lastPlayedFrame = payload
        }
        lastPlayPeak = peakOfInt16(payload)
        playQueue.async { [weak self] in self?.playOnQueue(payload) }
    }

    /// 把一帧按比例衰减（PLC 补出来的帧听着是"上一帧的回声"，不会像静音那么突兀）
    private func attenuate(_ data: Data, _ k: Double) -> Data {
        var out = data
        out.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            let n = raw.count / 2
            for i in 0..<n {
                base[i] = Int16(max(-32768, min(32767, Int(Double(base[i]) * k))))
            }
        }
        return out
    }

    private func playOnQueue(_ data: Data) {
        /* 引擎要是被掐停了（来电、别的 App 抢会话、我们自己抢麦时关过会话），
           这里先把它拉起来再排帧 —— 以前 playerReady 只要还是 true 就直接
           往一个已经停掉的引擎里 schedule，帧全被吞掉，表现就是「通话中但没声音」。 */
        if !(playerReady && player.isRunning && playerNode.isPlaying) { startPlaybackOnQueue() }
        guard playerReady, player.isRunning, let fmt = playFormat else {
            framesDropped += 1
            return
        }
        pendingFrames.append(data)
        drainPending(fmt)
    }

    /// 把待播的帧排进播放器：**排多少播多少**（中间不会断），
    /// 再用「排到什么时候」这个时间推算兜住延迟 —— 排得超过 1.5 秒就丢最老的压回 ~0.35 秒。
    /// 上一版是"只保留 3 帧"，结果播放端被拖慢（日志里 收到=286 排播=200），听着就是一顿一顿。
    private func drainPending(_ fmt: AVAudioFormat) {
        var until = max(Date(), queuedUntil)
        /* 抖动缓冲（2026-10-12 改进，用户报「通了有杂音」）：
           以前是「积压超过 1.5 秒才一次性狠丢一堆」—— 一次丢掉 ~1 秒的音频，
           听感上就是一声爆响/一顿断续（杂音的主要来源）。
           现在分两档、只单帧丢，并且**始终保 4 帧（160ms）垫子**：
             · 积压 > 400ms：温和追（一帧一帧丢，把播放点往前挪）
             · 积压 > 1500ms：快追（已经没法好好听了，丢到 200ms 为止）
           追的过程是"播放点往前挪 40ms"，不是把已排进播放器的内容扔掉，
           所以听不出大窟窿，最多一两声轻微顿挫。 */
        let backlog = until.timeIntervalSinceNow
        /* 2026-10-13：垫子深度改成**自适应**（bufferTarget，3~6 帧 = 120~240ms）——
           网络抖的时候上面 play() 会把它加厚，稳一会儿再慢慢放薄。
           以前固定 4 帧（160ms）：网络一抖就补不上，听着断断续续。 */
        if Date().timeIntervalSince(lastPlcAt) > 8, bufferTarget > 3 {
            bufferTarget -= 1
            lastPlcAt = Date()          // 稳了：每 8 秒往下退一档
        }
        let cushion = bufferTarget
        /* ⚠ 2026-10-14：原来是 backlog > 0.4s 就开始丢帧 —— 网络一抖（实测积压到 4 秒）
           就会把一半音频丢掉（听感：断断续续、听不清）。改成积压超过 0.8s 才开始丢，
           硬丢的阈值也从 1.5s 放到 2.5s：宁可稍微多延迟一点，也不要丢内容。 */
        if backlog > 0.4, pendingFrames.count > cushion {
            let hard = backlog > 1.5
            while pendingFrames.count > cushion {
                let now = until.timeIntervalSinceNow
                if hard ? (now <= 0.2) : (now <= 0.25) { break }
                pendingFrames.removeFirst()
                framesDropped += 1
                until = until.addingTimeInterval(-0.04)
            }
        }
        while !pendingFrames.isEmpty {
            let d = pendingFrames.removeFirst()
            let frames = d.count / 2
            guard frames > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else {
                framesDropped += 1
                continue
            }
            buf.frameLength = AVAudioFrameCount(frames)
            guard let ch = buf.int16ChannelData else {
                framesDropped += 1
                continue
            }
            d.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    memcpy(ch[0], base, frames * 2)
                }
            }
            playerNode.scheduleBuffer(buf, completionHandler: nil)
            framesScheduled += 1
            until = until.addingTimeInterval(0.04)
        }
        queuedUntil = until
        let now = queuedUntil.timeIntervalSinceNow
        if now > latencyPeak { latencyPeak = now }
    }

}
