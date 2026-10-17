import SwiftUI
import AVFoundation
import Speech
import Accelerate

/* ============================================================
   声音锁（微信「我 → 设置 → 账号与安全 → 声音锁」那一套）
   · 开通：屏幕给 8 位数字，按住读一遍；换一组数字，再读一遍
   · 使用：登录页点「声音锁」，读出屏幕上的数字 → 进去
   和微信一样是两道关：
     ① 数字 —— 屏幕上是随机的，必须真的念出来（用系统语音识别，**在本机认**，音频不出手机）
     ② 声纹 —— 录下来的频谱特征和开通时存的那份比对，模板只存这台手机的钥匙串
   声纹松紧后台能调：data/ui.json 里写 {"voiceMinScore": 0.42}（0~1，越大越严）
   ============================================================ */

enum VoiceLockStore {
    private static let onKey = "voiceLockOn"
    private static let printKey = "voiceLockPrint"
    private static let userKey = "voiceLockUser"

    /// 开通过没有（开关和模板都在才算）
    static var enabled: Bool { Keychain.get(onKey) == "1" && !template.isEmpty }
    /// 这把锁绑在哪个账号上（换账号要重设）
    static var boundUser: String { Keychain.get(userKey) ?? "" }

    /// 声纹模板：一串小数（频谱特征）
    static var template: [Double] {
        guard let s = Keychain.get(printKey), !s.isEmpty else { return [] }
        return s.split(separator: ",").compactMap { Double($0) }
    }

    static func enable(template t: [Double], user: String) {
        Keychain.set(t.map { String(format: "%.4f", $0) }.joined(separator: ","), for: printKey)
        Keychain.set(user, for: userKey)
        Keychain.set("1", for: onKey)
    }

    static func disable() {
        Keychain.remove(printKey)
        Keychain.remove(userKey)
        Keychain.remove(onKey)
    }

    /// 像不像同一个人：阈值默认 0.42，后台 data/ui.json 的 voiceMinScore 能改
    static var minScore: Double { Double(UIConfig.num("voiceMinScore", 0.42)) }

    static func voiceMatches(_ v: [Double]) -> (ok: Bool, score: Double) {
        let t = template
        guard !t.isEmpty, !v.isEmpty, t.count == v.count else { return (false, 0) }
        let s = VoicePrint.cosine(t, v)
        return (s >= minScore, s)
    }
}

/* ------------------------------------------------------------ 声纹特征 */

/// 把一段录音变成一串特征：24 个频带的能量（均值 + 波动），再标准化。
/// 同一个人读同一批数字，这串特征的形状很像；换个人就不像。
enum VoicePrint {
    static let bands = 24

    static func features(samples: [Float], sampleRate: Double) -> [Double] {
        let n = 1024, hop = 512
        guard samples.count > n * 4, sampleRate > 0 else { return [] }
        let half = n / 2
        let log2n = vDSP_Length(round(log2(Double(n))))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        /* 频带边界：80Hz 到 8kHz（超过采样率一半就砍掉）等分 */
        let top = min(8000.0, sampleRate / 2)
        let edges = melEdges(from: 80, to: max(top, 400), count: bands + 1)
        let binHz = sampleRate / Double(n)

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: n)
        var sum = [Double](repeating: 0, count: bands)
        var sumSq = [Double](repeating: 0, count: bands)
        var frames = 0

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                mags.withUnsafeMutableBufferPointer { mp in
                    frame.withUnsafeMutableBufferPointer { fp in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        var i = 0
                        while i + n <= samples.count {
                            for k in 0..<n { fp[k] = samples[i + k] * window[k] }
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                                vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                            }
                            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                            vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                            for b in 0..<bands {
                                let lo = max(1, Int(edges[b] / binHz))
                                let hi = min(half, max(lo + 1, Int(edges[b + 1] / binHz)))
                                var e = 0.0
                                for k in lo..<hi {
                                    let m = Double(mp[k])
                                    e += m * m
                                }
                                let lg = log(e + 1e-9)
                                sum[b] += lg
                                sumSq[b] += lg * lg
                            }
                            frames += 1
                            i += hop
                        }
                    }
                }
            }
        }
        guard frames > 3 else { return [] }

        var meanPart: [Double] = []
        var stdPart: [Double] = []
        for b in 0..<bands {
            let mean = sum[b] / Double(frames)
            let v = max(0, sumSq[b] / Double(frames) - mean * mean)
            meanPart.append(mean)
            stdPart.append(v.squareRoot())
        }
        /* 两半各自去均值再归一：整体音量大小就不影响比对了 */
        return normalize(meanPart) + normalize(stdPart)
    }

    static func average(_ a: [Double], _ b: [Double]) -> [Double] {
        guard a.count == b.count, !a.isEmpty else { return a.isEmpty ? b : a }
        var out = [Double](repeating: 0, count: a.count)
        for i in 0..<a.count { out[i] = (a[i] + b[i]) / 2 }
        return normalize(out)
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 1e-12, nb > 1e-12 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    private static func normalize(_ v: [Double]) -> [Double] {
        guard !v.isEmpty else { return v }
        let mean = v.reduce(0, +) / Double(v.count)
        let centered = v.map { $0 - mean }
        let norm = centered.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-9 else { return centered }
        return centered.map { $0 / norm }
    }

    private static func melEdges(from lo: Double, to hi: Double, count: Int) -> [Double] {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let a = mel(lo), b = mel(max(hi, lo + 200))
        return (0...count).map { hz(a + (b - a) * Double($0) / Double(count)) }
    }
}

/* ------------------------------------------------------------ 录音 + 本机识别 */

/// 录音线程和主线程都要碰的盒子：tap 回调跑在音频线程上，不能直接摸 View 的东西
private final class VoiceBox {
    private let lock = NSLock()
    private var buf: [Float] = []
    private var cap = 0
    private(set) var rate: Double = 44100

    func reset(rate: Double, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        self.rate = rate > 0 ? rate : 44100
        buf.removeAll(keepingCapacity: true)
        cap = Int(self.rate * seconds)
    }

    func add(_ p: UnsafePointer<Float>, _ n: Int) {
        lock.lock(); defer { lock.unlock() }
        guard buf.count < cap else { return }
        buf.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
    }

    func samples() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return buf
    }
}

/// 数字这一套（随机 8 位、把听到的话变成数字、对不上）—— 纯函数，谁都能用
enum VoiceDigits {
    /// 微信那种「随机 8 位数字」
    static func random() -> String {
        (0..<8).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    /// 识别出来的话 → 数字串（"一 二 三" / "123" / "幺二三" 都认）
    static func digits(_ s: String) -> String {
        let map: [Character: String] = ["零": "0", "〇": "0", "○": "0", "洞": "0",
                                        "一": "1", "幺": "1", "二": "2", "两": "2",
                                        "三": "3", "四": "4", "五": "5", "六": "6",
                                        "七": "7", "八": "8", "九": "9"]
        var out = ""
        for ch in s {
            if let d = ch.wholeNumberValue, d >= 0, d <= 9 {
                out.append(String(d))
            } else if let d = map[ch] {
                out += d
            }
        }
        return out
    }

    /// 读的和屏幕上的对不对：听漏一个字也放过（差一个字的距离）
    static func match(_ heard: String, _ want: String) -> Bool {
        guard want.count >= 4, !heard.isEmpty else { return false }
        if heard.contains(want) { return true }
        if abs(heard.count - want.count) > 2 { return false }
        return levenshtein(heard, want) <= 1
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...max(1, x.count) {
            cur[0] = i
            for j in 1...max(1, y.count) {
                let cost = (i <= x.count && j <= y.count && x[i - 1] == y[j - 1]) ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return prev[y.count]
    }
}

/// 按住说话那一套：一边录一边让系统在本机认字，松手算特征
@MainActor
final class VoiceReader: ObservableObject {
    @Published var listening = false
    @Published var level: Double = 0
    @Published var lastError = ""

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var said = ""
    private var done: (([Double], String) -> Void)?
    private var timeout: Task<Void, Never>?
    /// 权限那一串是异步的，这中间别被别人又按一下重复开（会开起两路麦克风）
    private var starting = false
    private let box = VoiceBox()

    func start(_ onDone: @escaping ([Double], String) -> Void) {
        guard !listening, !starting else { return }
        starting = true
        done = onDone
        said = ""
        lastError = ""
        SFSpeechRecognizer.requestAuthorization { [weak self] st in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard st == .authorized else {
                    self.lastError = "没给语音识别权限：设置 → 隐私 → 语音识别 里打开"
                    self.finish([])
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    DispatchQueue.main.async {
                        guard ok else {
                            self.lastError = "没给麦克风权限：设置 → 隐私 → 麦克风 里打开"
                            self.finish([])
                            return
                        }
                        self.begin()
                    }
                }
            }
        }
    }

    private func begin() {
        starting = false
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        do { try session.setActive(true, options: []) } catch {
            lastError = "麦克风被别的 App 占着，等一下再按"
            finish([])
            return
        }

        let node = engine.inputNode
        let fmt = node.outputFormat(forBus: 0)
        /* 格式没准备好（采样率 0）时硬装 tap 会抛 ObjC 异常、Swift 抓不住，直接闪退 */
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            lastError = "麦克风还没准备好，再按一次"
            finish([])
            return
        }
        box.reset(rate: fmt.sampleRate, seconds: 12)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        /* 声音锁的录音不出手机：只在**本机**认 */
        if recognizer?.supportsOnDeviceRecognition == true { req.requiresOnDeviceRecognition = true }
        request = req

        task = recognizer?.recognitionTask(with: req) { [weak self] res, _ in
            guard let self = self, let r = res else { return }
            let piece = r.bestTranscription.formattedString
            DispatchQueue.main.async { self.said = piece }
        }

        node.removeTap(onBus: 0)
        let tap = self.box          // 只把这个盒子交给音频线程（self 用弱引用，别让它俩互相拽住）
        node.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            req.append(buf)
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            tap.add(ch, n)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = Double((sum / Float(max(1, n))).squareRoot())
            let lv = min(1, rms * 14)
            DispatchQueue.main.async { [weak self] in self?.level = lv }
        }
        engine.prepare()
        do { try engine.start() } catch {
            lastError = "麦克风打不开，换个安静点的地方再试"
            finish([])
            return
        }
        listening = true
        /* 12 秒还没松手就自己收（别把麦克风一直占着） */
        timeout?.cancel()
        timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if !Task.isCancelled, self.listening { self.stop() }
        }
    }

    func stop() {
        guard listening else { return }
        listening = false
        starting = false
        timeout?.cancel()
        timeout = nil
        level = 0
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        /* 等系统把最后一句吐完（最多 1 秒），再算声纹 */
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            let s = self.box.samples()
            let rate = self.box.rate
            self.task?.cancel()
            self.task = nil
            self.request = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            self.finish(VoicePrint.features(samples: s, sampleRate: rate))
        }
    }

    /// 收工：把结果交给调用方（读不到就交空的）
    private func finish(_ feats: [Double]) {
        listening = false
        starting = false
        level = 0
        let f = done
        done = nil
        let said = self.said
        DispatchQueue.main.async { f?(feats, said) }
    }
}

/* ------------------------------------------------------------ 界面零件 */

/// 8 位数字（微信那种一格一格的大字）
struct VoiceDigitsRow: View {
    let digits: String

    var body: some View {
        let chars = digits.map(String.init)
        HStack(spacing: 6) {
            ForEach(chars.indices, id: \.self) { i in
                Text(chars[i])
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundColor(C.label)
                    .frame(width: 26)
            }
        }
    }
}

/// 说话时跳的那几根小竖条（微信录声音锁时也有）
struct VoiceLevelBars: View {
    var level: Double
    var active: Bool
    private let base: [CGFloat] = [8, 14, 20, 26, 32, 26, 20, 14, 8]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(base.indices, id: \.self) { i in
                Capsule()
                    .fill(active ? C.green : C.subLabel.opacity(0.3))
                    .frame(width: 3.5, height: active ? max(5, base[i] * (0.4 + level)) : base[i] * 0.55)
            }
        }
        .frame(height: 36)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// 「按住 读出以上数字」那颗按钮（松手就结束）
struct VoiceReadButton: View {
    var listening: Bool
    var disabled: Bool = false
    var onStart: () -> Void
    var onEnd: () -> Void

    var body: some View {
        Text(listening ? Tr("松开 结束") : Tr("按住 读出以上数字"))
            .font(pf(17, .medium))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(listening ? C.green.opacity(0.75) : C.green))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !disabled, !listening else { return }
                        onStart()
                    }
                    .onEnded { _ in if listening { onEnd() } }
            )
            .opacity(disabled ? 0.45 : 1)
            .padding(.horizontal, 30)
    }
}

/* ------------------------------------------------------------ 设置声音锁 */

/// 我 → 设置 → 账号与安全 → 声音锁（开通 / 重新设置 / 关闭）
struct VoiceLockSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var app: AppState

    @StateObject private var reader = VoiceReader()
    @State private var on = VoiceLockStore.enabled
    /// 0 还没开始 · 1 读第一遍 · 2 读第二遍
    @State private var step = 0
    @State private var digits = ""
    @State private var tip = ""
    @State private var error = ""
    @State private var firstPrint: [Double] = []
    /// 这次是来「关闭」的：先读一遍验身份
    @State private var closing = false
    /// 这次要先读一遍确认是本人（关 / 重设都要；第一次开通不用）
    @State private var verifyFirst = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("声音锁"), back: { dismiss() })
            if on && step == 0 {
                enabledBody
            } else {
                setupBody
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .onDisappear { if reader.listening { reader.stop() } }
    }

    /* 已经开了：只有两行，和微信一样 */
    private var enabledBody: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(Tr("声音锁已开启"))
                    .font(pf(15))
                    .foregroundColor(C.subLabel)
                    .padding(.top, 18)
                    .padding(.bottom, 18)
                row(Tr("重新设置声音锁")) { begin(closing: false) }
                row(Tr("关闭声音锁")) { begin(closing: true) }
            }
            .background(C.cardBg)
        }
        .background(C.pageBg)
    }

    /* 没开过 / 正在设置 */
    private var setupBody: some View {
        VStack(spacing: 16) {
            if step == 0 {
                Spacer(minLength: 30)
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 62))
                    .foregroundColor(C.green)
                Text(Tr("声音锁是用来登录的：设置时需要读出屏幕上的数字，并按提示再读一遍。"))
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .padding(.horizontal, 34)
                Button { begin(closing: false) } label: {
                    Text(Tr("开始设置"))
                        .font(pf(17, .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.green))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 30)
                .padding(.top, 6)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 20)
                Text(verifyFirst ? Tr("先读一遍，确认是你本人") : tip)
                    .font(pf(17, .medium))
                    .foregroundColor(C.label)
                VoiceDigitsRow(digits: digits)
                    .padding(.top, 2)
                if !error.isEmpty {
                    Text(error)
                        .font(pf(13))
                        .foregroundColor(Color(hexString: "#FA5151"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                } else {
                    Color.clear.frame(height: 16)
                }
                VoiceLevelBars(level: reader.level, active: reader.listening)
                VoiceReadButton(listening: reader.listening,
                                onStart: { reader.start { feats, said in handle(feats, said) } },
                                onEnd: { reader.stop() })
                Text(Tr("声音锁只在这台手机上有效，声纹不会上传"))
                    .font(pf(12))
                    .foregroundColor(C.subLabel)
                    .padding(.top, 4)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ title: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack {
                Text(title).font(pf(16)).foregroundColor(C.label)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(C.subLabel)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { HairLine(inset: 16) }
    }

    private func begin(closing: Bool) {
        self.closing = closing
        /* 已经开通过的：先读一遍确认是本人（微信也是这个顺序） */
        verifyFirst = VoiceLockStore.enabled
        step = 1
        firstPrint = []
        error = ""
        tip = Tr("请读出以下数字")
        digits = VoiceDigits.random()
    }

    /// 松手以后拿到（特征, 听到的话），在这里判定
    private func handle(_ feats: [Double], _ said: String) {
        if !reader.lastError.isEmpty {
            error = reader.lastError
            return
        }
        let heard = VoiceDigits.digits(said)
        guard VoiceDigits.match(heard, digits) else {
            error = heard.isEmpty ? Tr("没听清，凑近一点、大声一点再读一遍") : Tr("读的和屏幕上的数字不一样")
            digits = VoiceDigits.random()          // 换一组，别照着刚念的那组再来
            return
        }
        error = ""
        /* 已经开通过的：这一遍只是确认是本人（数字之外再比一次声纹） */
        if verifyFirst {
            let m = VoiceLockStore.voiceMatches(feats)
            if !m.ok {
                error = m.score > 0 ? Tr("这个声音和开通时不太像，再试一次") : Tr("再读一遍")
                return
            }
            verifyFirst = false
            error = ""
            if closing {
                VoiceLockStore.disable()
                on = false
                app.show(Tr("声音锁已关闭"))
                dismiss()
                return
            }
            /* 重新设置：验过之后从第一遍重新读 */
            step = 1
            firstPrint = []
            tip = Tr("请读出以下数字")
            digits = VoiceDigits.random()
            return
        }
        guard !feats.isEmpty else {
            error = Tr("没听清，再读一遍")
            return
        }
        if step == 1 {
            firstPrint = feats
            step = 2
            tip = Tr("再读一遍")
            digits = VoiceDigits.random()
            return
        }
        /* 两遍都过了：模板取两次的平均，只存这台手机的钥匙串 */
        VoiceLockStore.enable(template: VoicePrint.average(firstPrint, feats),
                              user: app.me?.username ?? "")
        on = true
        app.show(Tr("声音锁已开启：登录时可以读数字进"))
        dismiss()
    }
}

/* ------------------------------------------------------------ 用声音锁登录 */

/// 读屏幕上的数字 → 数字对 + 声纹像 → 放行（登录页点「声音锁」弹这个）
struct VoiceUnlockView: View {
    var onOk: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var reader = VoiceReader()
    @State private var digits = VoiceDigits.random()
    @State private var error = ""
    @State private var tries = 0
    @State private var shake = false

    private var locked: Bool { tries >= 3 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Text(Tr("取消"))
                        .font(pf(16))
                        .foregroundColor(C.label)
                        .frame(height: L.navH)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 10)

            VStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 34))
                    .foregroundColor(C.green)
                Text(locked ? Tr("声音锁没通过，用账号密码登录吧") : Tr("请读出以下数字"))
                    .font(pf(18, .medium))
                    .foregroundColor(C.label)
                if !locked {
                    VoiceDigitsRow(digits: digits)
                        .offset(x: shake ? 6 : 0)
                }
                if !error.isEmpty {
                    Text(error)
                        .font(pf(13))
                        .foregroundColor(Color(hexString: "#FA5151"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                } else {
                    Color.clear.frame(height: 16)
                }
                VoiceLevelBars(level: reader.level, active: reader.listening)
            }

            Spacer(minLength: 12)

            if !locked {
                VoiceReadButton(listening: reader.listening,
                                onStart: { reader.start { feats, said in handle(feats, said) } },
                                onEnd: { reader.stop() })
            }

            Spacer(minLength: 24)
        }
        .background(C.pageBg.ignoresSafeArea())
        .onDisappear { if reader.listening { reader.stop() } }
    }

    private func handle(_ feats: [Double], _ said: String) {
        if !reader.lastError.isEmpty {
            error = reader.lastError
            return
        }
        /* ① 数字对不对 */
        let heard = VoiceDigits.digits(said)
        guard VoiceDigits.match(heard, digits) else {
            fail(heard.isEmpty ? Tr("没听清，再读一遍") : Tr("读的数字不对"))
            return
        }
        /* ② 声纹像不像开通时的那个人 */
        let m = VoiceLockStore.voiceMatches(feats)
        guard m.ok else {
            fail(m.score > 0 ? Tr("这个声音和开通时不太像") : Tr("没听清，再读一遍"))
            return
        }
        onOk()
        dismiss()
    }

    private func fail(_ msg: String) {
        error = msg
        tries += 1
        digits = VoiceDigits.random()
        shake = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { shake = false }
    }
}
