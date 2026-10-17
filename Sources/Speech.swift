import AVFoundation

/* ============================================================
   文本朗读（和微信一样：长按一条消息 → 朗读）
   用系统语音念，中文优先；重复点会自动停掉上一次再重新念。
   ============================================================ */
final class Speaker {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()

    /// 用户在小星「语音设置」里选的音色（identifier；空 = 系统默认中文音色）
    static var chosenVoice = ""
    /// 语速（0.3~0.7，系统默认 0.5）
    static var chosenRate: Float = 0.5

    var isSpeaking: Bool { synth.isSpeaking }

    func speak(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        /* 念的时候别把音乐/通话彻底掐掉，只是压低一点（spokenAudio + duckOthers） */
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: t)
        /* 选了音色就用选的（小星语音设置里换的那款），没选就用系统默认中文音色 */
        if !Speaker.chosenVoice.isEmpty, let v = AVSpeechSynthesisVoice(identifier: Speaker.chosenVoice) {
            u.voice = v
        } else {
            u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        u.rate = Speaker.chosenRate
        synth.speak(u)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}
