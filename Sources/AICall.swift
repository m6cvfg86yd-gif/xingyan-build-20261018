import SwiftUI
import AVFoundation
import Speech

/// 说话 → 识别成文字 → 发给 AI → 把 AI 的回复念出来（贾维斯语音电话）
@MainActor
final class VoiceEngine: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var listening = false
    @Published var heard = ""
    @Published var status = "点一下麦克风开始说话"

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let synth = AVSpeechSynthesizer()
    private var onSpokenDone: (() -> Void)?
    private var autoStop: Task<Void, Never>?
    private var onText: ((String) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    func authorize(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { st in
            DispatchQueue.main.async { done(st == .authorized) }
        }
    }

    func start(_ onText: @escaping (String) -> Void) {
        stop()
        self.onText = onText
        heard = ""
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true, options: [])

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        /* 采样率是 0 时不能硬装 tap：ObjC 异常 Swift 抓不住，会直接闪退 */
        guard format.sampleRate > 0, format.channelCount > 0 else {
            status = "麦克风还没准备好，再点一次"
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
            req.append(buf)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            status = "麦克风打不开（检查权限）"
            return
        }
        listening = true
        status = "我在听…"

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let result = result {
                    self.heard = result.bestTranscription.formattedString
                    if result.isFinal { self.finishSpeaking() }
                }
                if error != nil { self.finishSpeaking() }
            }
        }

        autoStop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard let self = self, !Task.isCancelled else { return }
            if self.listening { self.finishSpeaking() }
        }
    }

    private func finishSpeaking() {
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        if !text.isEmpty { onText?(text) }
    }

    func stop() {
        autoStop?.cancel()
        autoStop = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        listening = false
    }

    func speak(_ text: String, done: @escaping () -> Void) {
        onSpokenDone = done
        let clean = text.replacingOccurrences(of: "```", with: " ")
            .replacingOccurrences(of: "#", with: "")
        let u = AVSpeechUtterance(string: String(clean.prefix(220)))
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = 0.5
        u.pitchMultiplier = 0.72          // 压一点，听着像男声
        synth.speak(u)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let cb = self.onSpokenDone
            self.onSpokenDone = nil
            cb?()
        }
    }
}

/* ============================================================ 通话界面 */

struct AICallView: View {
    let chat: Chat

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = VoiceEngine()

    @State private var phase = "正在接通…"
    @State private var reply = ""
    @State private var busy = false
    @State private var denyReason = ""
    /// 点上面那个大头像 → 弹 AI 的名片（微信里点通话页头像就是这个）
    @State private var showCard = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1B1B1F), Color(hex: 0x0B0B0D)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 70)
                Button { showCard = true } label: {
                    Avatar(path: chat.avatar ?? "", size: 96, radius: 16)
                }
                .buttonStyle(.plain)
                Text(chat.name)
                    .font(pf(22, .medium))
                    .foregroundColor(.white)
                    .padding(.top, 16)
                Text(phase)
                    .font(pf(14))
                    .foregroundColor(Color.white.opacity(0.7))
                    .padding(.top, 8)

                if !voice.heard.isEmpty {
                    Text("你说：\(voice.heard)")
                        .font(pf(15))
                        .foregroundColor(Color.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .padding(.top, 20)
                }

                if !reply.isEmpty {
                    ScrollView {
                        Text(reply)
                            .font(pf(15))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(maxHeight: 210)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                }

                if !denyReason.isEmpty {
                    Text(denyReason)
                        .font(pf(13))
                        .foregroundColor(Color(hex: 0xFFB3B3))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .padding(.top, 14)
                }

                Spacer()

                Button {
                    if voice.listening { voice.stop() }
                    else { startListening() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(voice.listening ? Color(hex: 0x19A47A) : Color.white.opacity(0.16))
                            .frame(width: 84, height: 84)
                        SVGIcon(markup: I.voice, size: 38, color: .white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Text(voice.status)
                    .font(pf(13))
                    .foregroundColor(Color.white.opacity(0.7))
                    .padding(.top, 12)

                Button {
                    voice.stop()
                    dismiss()
                } label: {
                    Text(Tr("挂断"))
                        .font(pf(17))
                        .foregroundColor(.white)
                        .frame(width: 150, height: 48)
                        .background(RoundedRectangle(cornerRadius: 24).fill(Color(hex: 0xFA5151)))
                }
                .buttonStyle(.plain)
                .padding(.top, 26)
                .padding(.bottom, 40)
            }
        }
        .task {
            voice.authorize { ok in
                if ok {
                    phase = "已接通"
                    startListening()
                } else {
                    phase = "没给语音识别权限"
                }
            }
        }
        .onDisappear { voice.stop() }
        .sheet(isPresented: $showCard) {
            BotCardView(chat: chat).environmentObject(app)
        }
    }

    private func startListening() {
        guard !busy else { return }
        voice.start { text in
            ask(text)
        }
    }

    private func ask(_ text: String) {
        busy = true
        phase = "AI助手在想…"
        reply = ""
        denyReason = ""
        Task {
            let before = (try? await API.shared.messages(chatId: chat.id, limit: 4))?.messages.last?.id ?? ""
            _ = try? await API.shared.send(chatId: chat.id, kind: "text", content: text)
            var answer: Message?
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let list = (try? await API.shared.messages(chatId: chat.id, limit: 6))?.messages else { continue }
                if let last = list.last, last.id != before, last.senderId != app.me?.id {
                    answer = last
                    break
                }
            }
            busy = false
            if let answer = answer {
                reply = answer.body
                if answer.body.contains("余额") || answer.body.contains("额度不足") {
                    denyReason = answer.body
                }
                phase = "AI助手在说话…"
                voice.speak(answer.body) {
                    phase = "已接通"
                    startListening()
                }
            } else {
                phase = "他还没回，再说一次试试"
                denyReason = "没等到回复（可能是 AI 余额不足或网络卡了）"
            }
            await app.loadChats()
        }
    }
}
