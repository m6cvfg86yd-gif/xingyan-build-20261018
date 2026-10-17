import Foundation
import AVFoundation
import Combine

/* ============================================================
   铃声：来电铃声 + 回铃音（「嘟——」那种）

   不用打包音频文件，直接用 AVAudioEngine 现场合成正弦波音符，
   所以是**真的会响**，而且想加铃声只要加一行音阶。
   铃声在「我 → 个人信息 → 来电铃声」里能换、能试听。
   ============================================================ */

@MainActor
final class Ringtone: ObservableObject {
    static let shared = Ringtone()

    enum Kind { case none, incoming, ringback }

    struct Tone: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// 可选铃声（id 存在本机，来电时用）
    static let all: [Tone] = [
        Tone(id: "wechat", name: "默认"),
        Tone(id: "marimba", name: "马林巴"),
        Tone(id: "chime", name: "清脆"),
        Tone(id: "bubble", name: "气泡"),
        Tone(id: "pulse", name: "脉冲"),
        Tone(id: "classic", name: "经典电话"),
        Tone(id: "quiet", name: "轻柔")
    ]

    @Published private(set) var kind: Kind = .none
    @Published private(set) var previewing = ""
    @Published var current: String

    /// 当前铃声的名字（设置页那行显示用）
    var currentName: String {
        Ringtone.all.first(where: { $0.id == current })?.name ?? "默认"
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// 回铃音单独走 AVAudioPlayer。
    /// iOS **没有向第三方开放电话 App 的私有拨号音**；这里用系统 AVFoundation
    /// 播放标准 450Hz「响 1 秒 / 停 4 秒」回铃音，走的是 iOS 原生音频会话。
    /// 独立播放器也比之前的 AVAudioEngine 更不容易被通话会话切换掐停。
    private var ringbackPlayer: AVAudioPlayer?
    private let rate: Double = 44100
    private var previewTask: Task<Void, Never>?

    private init() {
        current = UserDefaults.standard.string(forKey: "chris.ringtone") ?? "wechat"
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
    }

    /* ---------------------------------------------------------- 对外 */

    /// 来电铃声响起来（重复播放，直到停）
    func startIncoming() { play(kind: .incoming) }
    /// 呼出时的回铃音（嘟——嘟——）
    func startRingback() {
        stopPlaybackOnly()
        kind = .ringback
        activate()
        guard let data = makeWav(Ringtone.ringback),
              let p = try? AVAudioPlayer(data: data) else {
            play(kind: .ringback)       // 极端情况退回原来的引擎
            return
        }
        p.numberOfLoops = -1
        p.volume = 0.72
        p.prepareToPlay()
        ringbackPlayer = p
        p.play()
    }

    func stop() {
        stopPlaybackOnly()
        kind = .none
        deactivate()
    }

    private func stopPlaybackOnly() {
        previewTask?.cancel()
        previewTask = nil
        previewing = ""
        ringbackPlayer?.stop()
        ringbackPlayer = nil
        player.stop()
    }

    /// 设置页试听：放 4 秒自己停
    func preview(_ id: String) {
        stop()
        previewing = id
        activate()
        guard let buf = makeBuffer(melody(id)) else { return }
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: .loops)
        if !engine.isRunning { try? engine.start() }
        player.play()
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self = self, !Task.isCancelled else { return }
            if self.kind == .none { self.stop() }
        }
    }

    /* ---------------------------------------------------------- 内部 */

    private func play(kind: Kind) {
        ringbackPlayer?.stop()
        ringbackPlayer = nil
        self.kind = kind
        previewTask?.cancel()
        previewing = ""
        activate()
        guard let buf = makeBuffer(kind == .ringback ? Ringtone.ringback : melody(current)) else { return }
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: .loops)
        if !engine.isRunning { try? engine.start() }
        player.play()
    }

    /// 通话铃声要能听见（静音键也响），所以用 playAndRecord + 外放
    private func activate() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? s.setActive(true)
    }

    private func deactivate() {
        if engine.isRunning { engine.pause() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private struct Note {
        let freq: Double
        let dur: Double
    }

    /// 回铃音（呼出时听到的「嘟—— 嘟——」）：用户选的 1 号 —— **450Hz 单音，
    /// 响 1 秒 / 停 4 秒**（跟真手机打电话那个标准回铃音一样）。
    /// 它跟「来电铃声」是两条独立的音轨，不受铃声选择影响。
    private static let ringback: [Note] = [Note(freq: 450, dur: 1.0), Note(freq: 0, dur: 4.0)]

    /// 每种铃声就是一段音阶
    private func melody(_ id: String) -> [Note] {
        switch id {
        case "marimba":
            return [.init(freq: 523, dur: 0.16), .init(freq: 659, dur: 0.16), .init(freq: 784, dur: 0.16),
                    .init(freq: 1046, dur: 0.30), .init(freq: 0, dur: 0.12),
                    .init(freq: 784, dur: 0.16), .init(freq: 1046, dur: 0.42), .init(freq: 0, dur: 0.5)]
        case "chime":
            return [.init(freq: 988, dur: 0.14), .init(freq: 1319, dur: 0.14), .init(freq: 1568, dur: 0.34),
                    .init(freq: 0, dur: 0.6)]
        case "bubble":
            return [.init(freq: 880, dur: 0.09), .init(freq: 0, dur: 0.05),
                    .init(freq: 1175, dur: 0.09), .init(freq: 0, dur: 0.05),
                    .init(freq: 880, dur: 0.09), .init(freq: 0, dur: 0.5)]
        case "pulse":
            return [.init(freq: 660, dur: 0.22), .init(freq: 0, dur: 0.10),
                    .init(freq: 660, dur: 0.22), .init(freq: 0, dur: 0.8)]
        case "classic":
            return [.init(freq: 440, dur: 0.4), .init(freq: 480, dur: 0.4), .init(freq: 0, dur: 1.4)]
        case "quiet":
            return [.init(freq: 587, dur: 0.5), .init(freq: 0, dur: 0.3), .init(freq: 494, dur: 0.6), .init(freq: 0, dur: 1.4)]
        default:   // 微信
            return [.init(freq: 659, dur: 0.16), .init(freq: 784, dur: 0.16), .init(freq: 988, dur: 0.16),
                    .init(freq: 1319, dur: 0.34), .init(freq: 0, dur: 0.18),
                    .init(freq: 988, dur: 0.16), .init(freq: 1175, dur: 0.16),
                    .init(freq: 1319, dur: 0.42), .init(freq: 0, dur: 0.6)]
        }
    }

    private func makeBuffer(_ notes: [Note]) -> AVAudioPCMBuffer? {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let total = notes.reduce(0.0) { $0 + $1.dur }
        let frames = AVAudioFrameCount(max(1, total * rate))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames),
              let ptr = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = frames
        var i = 0
        for n in notes {
            let count = Int(n.dur * rate)
            for k in 0..<count where i < Int(frames) {
                let t = Double(k) / rate
                var v = 0.0
                if n.freq > 0 {
                    // 正弦 + 一点二次谐波，前后淡入淡出，听起来像铃声而不是"滴"声
                    let env = min(1, min(t / 0.012, max(0, (n.dur - t) / 0.06)))
                    v = (sin(2 * .pi * n.freq * t) * 0.62 + sin(4 * .pi * n.freq * t) * 0.2) * env
                }
                ptr[i] = Float(v * 0.55)
                i += 1
            }
        }
        return buf
    }

    /// 标准 PCM WAV：AVAudioPlayer 直接读内存，不额外打包音频文件。
    private func makeWav(_ notes: [Note]) -> Data? {
        let sr = Int(rate)
        let total = notes.reduce(0.0) { $0 + $1.dur }
        let frameCount = max(1, Int(total * rate))
        var pcm = Data()
        pcm.reserveCapacity(frameCount * 2)

        for n in notes {
            let count = Int(n.dur * rate)
            for k in 0..<count {
                let t = Double(k) / rate
                var v = 0.0
                if n.freq > 0 {
                    let env = min(1, min(t / 0.012, max(0, (n.dur - t) / 0.06)))
                    v = (sin(2 * .pi * n.freq * t) * 0.68
                         + sin(4 * .pi * n.freq * t) * 0.12) * env * 0.62
                }
                var sample = Int16(clamping: Int(v * 32767)).littleEndian
                withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
            }
        }

        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(littleEndian(UInt32(36 + pcm.count)))
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        wav.append(littleEndian(UInt32(16)))
        wav.append(littleEndian(UInt16(1)))          // PCM
        wav.append(littleEndian(UInt16(1)))          // mono
        wav.append(littleEndian(UInt32(sr)))
        wav.append(littleEndian(UInt32(sr * 2)))     // byte rate
        wav.append(littleEndian(UInt16(2)))          // block align
        wav.append(littleEndian(UInt16(16)))         // bits
        wav.append(contentsOf: Array("data".utf8))
        wav.append(littleEndian(UInt32(pcm.count)))
        wav.append(pcm)
        return wav
    }

    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Data($0) }
    }
}
