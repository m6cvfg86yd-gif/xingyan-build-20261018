import Foundation
import AVFoundation
import SwiftUI
import TXLiteAVSDK_TRTC

/* ============================================================
   真人变声器

   两条路，都要求「听起来还是真人」而不是机器人音：

   ⚠ 只做「真人嗓」：不做小孩音 / 电子音 / 机器人那种（那是 QQ 变声器的路子）。

   ① 通话（实时）：用腾讯云 TRTC 自带的变声（大叔 / 萝莉 / 空灵）+ 混响（磁性 / 录音棚）
      这是声学算法做的，音质干净、不刺耳，就是换了个人的嗓子；
      进房后立刻生效，通话中改预设也马上变，不用挂断重打。

   ② 语音消息（录完再处理）：本机用 AVAudioEngine 的离线渲染做，
      「变速换嗓 + 时间伸缩还原语速」：变速会把音高**和共鸣腔一起**挪，
      等于换了个大小的嗓子；只挪音高不动共鸣腔，听起来就是假音。
      再叠两段均衡补回胸腔/头腔的共鸣，可选一点点混响（电台/空灵）。
      处理完全在本机，原声不会上传。

   预设是两边共用的：选了「磁性男声」，打电话和发语音都用它。
   ============================================================ */

/// 一个变声预设
struct VoiceEffect: Identifiable, Equatable {
    let id: String
    let name: String
    let hint: String

    /* 通话（TRTC 实时变声） */
    let trtcChange: Int        // TXVoiceChangeType 原始值：0 原声 2 萝莉 3 大叔 6 外国腔 11 空灵…
    let trtcReverb: Int        // TXVoiceReverbType 原始值：0 关 7 磁性 8 空灵 9 录音棚…

    /* 语音消息（本机离线处理） */
    /// 整体变速比（1.18 = 快 18%）。这是"像真人"的关键：
    /// 变速会把**音高和共鸣腔一起**抬高/压低（等于换了个大小的嗓子），
    /// 后面再用时间伸缩把语速拉回原样 —— 只调音高不改共鸣腔，听起来就是"假音/电子音"。
    let speed: Float
    let pitch: Float           // 额外微调音高，单位「音分」（100 音分 = 1 个半音）
    let lowGain: Float         // 低频货架增益 dB（正=更厚更沉）
    let highGain: Float        // 高频货架增益 dB（正=更亮更年轻）
    let wet: Float             // 混响湿度 0…100（0 = 干声，最"真实"）
}

/// 变声预设表 + 我选的那个（存本机，和账号无关）
@MainActor
final class VoiceChangerStore: ObservableObject {
    static let shared = VoiceChangerStore()

    static let all: [VoiceEffect] = [
        VoiceEffect(id: "origin", name: "原声", hint: "不做任何处理",
                    trtcChange: 0, trtcReverb: 0,
                    speed: 1.0, pitch: 0, lowGain: 0, highGain: 0, wet: 0),

        VoiceEffect(id: "girl", name: "温柔女声", hint: "真女声的嗓子（不是小孩音那种假声）",
                    trtcChange: 2, trtcReverb: 0,
                    speed: 1.19, pitch: 0, lowGain: -3, highGain: 2.5, wet: 0),

        VoiceEffect(id: "uncle", name: "磁性男声", hint: "低沉、有厚度，成熟男人的嗓子",
                    trtcChange: 3, trtcReverb: 7,
                    speed: 0.88, pitch: 0, lowGain: 3.5, highGain: -2.5, wet: 0),

        VoiceEffect(id: "boy", name: "清亮少年", hint: "年轻、干净，像二十来岁的小伙子",
                    trtcChange: 0, trtcReverb: 9,
                    speed: 1.10, pitch: 0, lowGain: -1.5, highGain: 1.6, wet: 0),

        VoiceEffect(id: "kidboy", name: "小男孩", hint: "童声，像七八岁的小男孩",
                    trtcChange: 1, trtcReverb: 0,
                    speed: 1.30, pitch: 0, lowGain: -2, highGain: 1.2, wet: 0),

        VoiceEffect(id: "kidgirl", name: "小女孩", hint: "童声，像七八岁的小女孩",
                    trtcChange: 2, trtcReverb: 0,
                    speed: 1.40, pitch: 0, lowGain: -3, highGain: 2.0, wet: 0),

        VoiceEffect(id: "radio", name: "电台主播", hint: "贴耳的低沉嗓 + 录音棚质感",
                    trtcChange: 0, trtcReverb: 9,
                    speed: 0.94, pitch: 0, lowGain: 2.5, highGain: 1.5, wet: 8),

        VoiceEffect(id: "ethereal", name: "空灵嗓", hint: "轻、软、带一点空间感（还是真人嗓）",
                    trtcChange: 11, trtcReverb: 8,
                    speed: 1.09, pitch: 0, lowGain: -1.5, highGain: 1.5, wet: 16),
    ]

    @Published private(set) var presetId: String = "origin"

    var current: VoiceEffect {
        VoiceChangerStore.all.first { $0.id == presetId } ?? VoiceChangerStore.all[0]
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "chris.voiceEffect") ?? "origin"
        presetId = VoiceChangerStore.all.contains { $0.id == saved } ? saved : "origin"
    }

    func select(_ id: String) {
        guard VoiceChangerStore.all.contains(where: { $0.id == id }) else { return }
        presetId = id
        UserDefaults.standard.set(id, forKey: "chris.voiceEffect")
        /* 正在打电话的话，立刻换成新声音（TRTC 支持通话中随时改，不用挂断重打） */
        TRTCBridge.shared.applyVoiceEffect()
    }
}

/// 本机离线变声（语音消息用）
enum VoiceChanger {
    /// 把录好的语音按预设处理一遍。**处理失败就返回原文件** —— 变声是锦上添花，
    /// 绝不能因为它让用户发不出语音。
    static func process(_ input: URL, preset: VoiceEffect) -> URL {
        guard preset.id != "origin" else { return input }
        do {
            let out = try render(input, preset)
            return out
        } catch {
            return input
        }
    }

    private static func render(_ input: URL, _ p: VoiceEffect) throws -> URL {
        let inFile = try AVAudioFile(forReading: input)
        let fmt = inFile.processingFormat
        let total = inFile.length
        guard total > 0, fmt.sampleRate > 0 else { return input }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let speed = AVAudioUnitVarispeed()
        let pitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 2)
        let reverb = AVAudioUnitReverb()

        /* 换嗓，分两步（这是"像真人"的核心）：
           ① 变速：音高和共鸣腔一起抬高/压低 —— 等于换了一个人大小的嗓子。只调音高、
              不动共鸣腔，出来就是那种"假音"（QQ 变声器的味道）。
           ② 再把语速拉回原样：时间伸缩不改音高，所以音色留在新嗓子上，
              时长和原来一样（气泡上写的秒数才对得上）。 */
        speed.rate = p.speed
        pitch.rate = p.speed > 0 ? 1.0 / p.speed : 1.0
        pitch.pitch = p.pitch
        pitch.overlap = 8.0

        /* 两段货架 EQ：换嗓以后"腔体大小"不匹配才显得假，这里补回来 */
        eq.bands[0].filterType = .lowShelf
        eq.bands[0].frequency = 200
        eq.bands[0].gain = p.lowGain
        eq.bands[0].bypass = (p.lowGain == 0)
        eq.bands[1].filterType = .highShelf
        eq.bands[1].frequency = 3200
        eq.bands[1].gain = p.highGain
        eq.bands[1].bypass = (p.highGain == 0)

        reverb.loadFactoryPreset(.mediumRoom)
        reverb.wetDryMix = p.wet

        engine.attach(player)
        engine.attach(speed)
        engine.attach(pitch)
        engine.attach(eq)
        engine.attach(reverb)
        engine.connect(player, to: speed, format: fmt)
        engine.connect(speed, to: pitch, format: fmt)
        engine.connect(pitch, to: eq, format: fmt)
        engine.connect(eq, to: reverb, format: fmt)
        engine.connect(reverb, to: engine.mainMixerNode, format: fmt)

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vfx-\(UUID().uuidString).m4a")
        let outSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let outFile = try AVAudioFile(forWriting: outURL, settings: outSettings)

        /* ⚠ 「离线渲染」要在 start 之前打开；maximumFrameCount 也要等打开之后才读得到真值 */
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        try engine.start()
        let maxFrames = engine.manualRenderingMaximumFrameCount

        /* 分块调度（语音最长 60 秒，内存完全吃得下） */
        var scheduled: AVAudioFramePosition = 0
        var lastBufferDone = false
        while scheduled < total {
            let want = AVAudioFrameCount(min(Int64(maxFrames), total - scheduled))
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: want) else { break }
            inFile.framePosition = scheduled
            try inFile.read(into: buf, frameCount: want)
            if buf.frameLength == 0 { break }
            scheduled += AVAudioFramePosition(buf.frameLength)
            player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in
                lastBufferDone = true
            }
        }
        player.play()

        guard let renderBuf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                              frameCapacity: maxFrames) else {
            engine.stop()
            return input
        }

        /* 混响尾巴要放一会儿，但必须有底：渲染到「原长 + 0.6 秒」为止 */
        let tailFrames = AVAudioFramePosition(fmt.sampleRate * 0.6)
        var rendered: AVAudioFramePosition = 0
        var spins = 0
        while true {
            let status = try engine.renderOffline(maxFrames, to: renderBuf)
            if status == .success {
                if renderBuf.frameLength == 0 { break }
                try outFile.write(from: renderBuf)
                rendered += AVAudioFramePosition(renderBuf.frameLength)
            }
            if lastBufferDone, rendered >= total + tailFrames { break }
            /* 安全阀：万一完成回调没来（离线渲染偶发），也别让"发语音"卡死在这儿 */
            // 2000 × 4096 帧 ≈ 六分钟，正常一段语音几十次就渲染完了
            spins += 1
            if spins > 2000 { break }
        }
        engine.stop()
        player.stop()
        return outURL
    }
}

/* ============================================================
   变声设置页（我 → 设置 → 通用 → 语音变声）
   ============================================================ */

struct VoiceChangerView: View {
    @ObservedObject private var store = VoiceChangerStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("语音变声"), back: { dismiss() })
            ScrollView {
                VStack(spacing: 0) {
                    Text("发语音和打电话都会用这个声音。只做真人嗓（不做小孩音、电子音那种假声）：通话走实时变声，语音消息在你手机上处理完再发，原声不会上传。\n\n换嗓是把音高和共鸣腔一起调（等于换一个嗓门大小），所以听起来还是真人说话，只是像另一个人。")
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    GroupCard {
                        ForEach(Array(VoiceChangerStore.all.enumerated()), id: \.element.id) { idx, e in
                            if idx > 0 { HairLine(inset: 16) }
                            Button { store.select(e.id) } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(e.name).font(pf(17)).foregroundColor(C.label)
                                        Text(e.hint).font(pf(12.5)).foregroundColor(C.subLabel)
                                    }
                                    Spacer(minLength: 8)
                                    if store.presetId == e.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(C.green)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
    }
}
