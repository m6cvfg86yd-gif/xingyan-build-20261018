import SwiftUI
import Speech
import AVFoundation

/// 聊天输入框里那个小喇叭：**语音转文字**（和微信一样）
/// 点一下开始听，边说文字边出现在输入框里；停口 1.4 秒自动收工，也可以再点一下停。
@MainActor
final class Dictation: NSObject, ObservableObject {
    @Published var listening = false
    @Published var text = ""
    @Published var error = ""

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onText: ((String) -> Void)?
    private var silence: Timer?
    private var started = false
    /// 已经说过的部分（识别会自动「翻页」，这里把每次的结果接起来，别丢字）
    private var settled = ""
    private var lastEmitted = ""
    private var beganAt = Date()
    private var lastRollover = Date.distantPast

    /// 点一下开 / 点一下关
    func toggle(_ onText: @escaping (String) -> Void) {
        if listening || started { stop() } else { start(onText) }
    }

    func start(_ onText: @escaping (String) -> Void) {
        self.onText = onText
        text = ""
        error = ""
        settled = ""
        lastEmitted = ""
        beganAt = Date()
        SFSpeechRecognizer.requestAuthorization { [weak self] st in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard st == .authorized else {
                    self.error = "没给语音识别权限：设置 → 隐私 → 语音识别 里打开"
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    DispatchQueue.main.async {
                        guard ok else {
                            self.error = "没给麦克风权限：设置 → 隐私 → 麦克风 里打开"
                            return
                        }
                        self.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .default, options: [.duckOthers])
        do {
            try session.setActive(true, options: [])
        } catch {
            self.error = "麦克风被别的 App 占着，等一下再点一次"
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation          // 按「听写」来识别，长句子更准、少断
        request = req

        let node = engine.inputNode
        let fmt = node.outputFormat(forBus: 0)
        /* 格式没准备好（采样率 0）时千万别硬装 tap —— 系统会抛 ObjC 异常，
           那个异常 Swift 的 do/catch 抓不住，直接闪退（线上崩过）。 */
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            self.error = "麦克风还没准备好，再点一次话筒"
            return
        }
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in req.append(buf) }
        engine.prepare()
        do { try engine.start() } catch {
            self.error = "麦克风打不开，等一下再试"
            return
        }
        listening = true
        started = true
        bumpSilence()

        task = recognizer?.recognitionTask(with: req) { [weak self] result, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let result = result {
                    let piece = result.bestTranscription.formattedString
                    let full = self.settled.isEmpty ? piece : (self.settled + piece)
                    if full != self.lastEmitted {
                        self.lastEmitted = full
                        self.text = full
                        self.onText?(full)
                        self.bumpSilence()          // 只在真的听到新字时才重新计时
                    }
                    if result.isFinal {
                        self.settled = full
                        self.rollover()             // 不打断：接着听下一段
                    }
                }
                if err != nil {
                    /* 识别偶尔会自己结束/报错，只要用户没点停就接着听，别中途断掉 */
                    if self.listening {
                        self.settled = self.lastEmitted
                        self.rollover()
                    }
                }
            }
        }
    }

    /// 一句话说完（停口）才收工：2.4 秒没有新字就停
    private func bumpSilence() {
        silence?.invalidate()
        silence = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: false) { _ in
            Task { @MainActor in self.stop() }
        }
    }

    /// 识别任务到点会自己结束 —— 只要还在听，就马上开一段新的接着听（最多 5 分钟）
    private func rollover() {
        guard listening else { return }
        guard Date().timeIntervalSince(beganAt) < 300 else { stop(); return }
        /* 如果识别一直起不来（连续失败），别在这儿死循环 */
        if Date().timeIntervalSince(lastRollover) < 0.6 { stop(); return }
        lastRollover = Date()
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self = self, self.listening else { return }
            self.begin()
        }
    }

    func stop() {
        silence?.invalidate()
        silence = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        listening = false
        started = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
