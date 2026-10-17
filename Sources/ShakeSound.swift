import Foundation
import AVFoundation

/* ============================================================
   摇一摇的音效（和铃铛一样，全部现场合成，不打包音频文件）
     · click：摇一下的「咔」——一小段噪声 + 很快的衰减，像木头碰一下
     · ding ：摇到人的「叮——」——两个正弦音叠在一起慢慢衰减
   用 .playback + mixWithOthers：静音键也不影响（摇一摇本来就要听得见），
   同时不会把别人正在听的音乐掐掉。
   ============================================================ */

@MainActor
final class ShakeSound {
    static let shared = ShakeSound()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let rate = 44100.0
    private var ready = false

    private init() { }

    private func prepare() {
        guard !ready else { return }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        ready = true
    }

    /// 摇一下：咔
    func click() { play(makeClick()) }
    /// 摇到人：叮——
    func ding() { play(makeDing()) }

    private func play(_ buf: AVAudioPCMBuffer?) {
        guard let buf = buf else { return }
        prepare()
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
        if !engine.isRunning { try? engine.start() }
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
        player.play()
    }

    private func buffer(seconds: Double, fill: (Double) -> Double) -> AVAudioPCMBuffer? {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let n = AVAudioFrameCount(seconds * rate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
        buf.frameLength = n
        guard let ch = buf.floatChannelData?[0] else { return nil }
        for i in 0..<Int(n) {
            let t = Double(i) / rate
            ch[i] = Float(max(-1, min(1, fill(t))))
        }
        return buf
    }

    /// 「咔」：噪声 + 极快衰减，再叠一点点低频，听着像木头/塑料碰一下
    private func makeClick() -> AVAudioPCMBuffer? {
        var seed: UInt64 = 0x1234_5678
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) & 0xFFFF) / 32768.0 - 1.0
        }
        return buffer(seconds: 0.09) { t in
            let env = exp(-t * 55)
            let body = sin(2 * .pi * 180 * t) * exp(-t * 80) * 0.35
            return (noise() * 0.55 + body) * env
        }
    }

    /// 「叮——」：两个音（1319 + 1976Hz）一起响，慢慢衰减
    private func makeDing() -> AVAudioPCMBuffer? {
        buffer(seconds: 0.7) { t in
            let env = exp(-t * 4.2)
            let a = sin(2 * .pi * 1318.5 * t) * 0.5
            let b = sin(2 * .pi * 1975.5 * t) * 0.32
            let c = sin(2 * .pi * 2637.0 * t) * 0.16
            let attack = min(1, t / 0.006)          // 起音 6ms，别「噗」一下
            return (a + b + c) * env * attack
        }
    }
}
