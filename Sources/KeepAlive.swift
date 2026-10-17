import Foundation
import AVFoundation

/* ============================================================
   后台保活（不需要付费开发者账号也能收到通知的办法）

   iOS 一旦把 App 挂起，那条长连接就断了 —— 来消息也弹不出通知。
   App 里已经声明了 audio 后台模式，所以这里在**退到后台**时放一段
   「完全静音」的音频循环，系统就会让进程继续活着：
     · 长连接不断 → 服务器推的消息照样收得到
     · 收到消息就发本地通知（LocalNotify）→ 锁屏/后台都能看到、点通知直接进聊天
   限制（如实说明）：上滑「强杀」之后进程没了，谁都叫不醒，只有真 APNs 能做到。

   注意：**通话中不保活** —— 通话自己管音频会话，这里不去抢。
   ============================================================ */

@MainActor
final class KeepAlive {
    static let shared = KeepAlive()
    private init() {}

    private var player: AVAudioPlayer?
    private(set) var running = false

    /// 1 秒 8kHz 单声道静音 WAV（44 字节头 + 全 0 数据）
    private static func silentWavData(seconds: Int = 1, sampleRate: Int = 8000) -> Data {
        let dataBytes = seconds * sampleRate * 2          // 16-bit
        var d = Data()
        func le32(_ v: Int) -> Data { var x = UInt32(v).littleEndian; return Data(bytes: &x, count: 4) }
        func le16(_ v: Int) -> Data { var x = UInt16(v).littleEndian; return Data(bytes: &x, count: 2) }
        d.append("RIFF".data(using: .ascii)!)
        d.append(le32(36 + dataBytes))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        d.append(le32(16))
        d.append(le16(1))                                  // PCM
        d.append(le16(1))                                  // 单声道
        d.append(le32(sampleRate))
        d.append(le32(sampleRate * 2))                     // 字节率
        d.append(le16(2))                                  // 块对齐
        d.append(le16(16))                                 // 位深
        d.append("data".data(using: .ascii)!)
        d.append(le32(dataBytes))
        d.append(Data(count: dataBytes))                   // 全静音
        return d
    }

    /// 退到后台时调用：开始保活（已经开着就什么都不做）
    func start() {
        guard !running else { return }
        /* 通话中别抢音频；登录前也不用保活（没长连接） */
        if CallCenter.shared.phase.isBusy { return }
        guard !API.shared.token.isEmpty else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            /* 音乐在放的时候**不改类别**（改类别可能把正在放的那首歌掐掉），
               只把会话激活就行 —— 保活的静音和音乐是同一个会话里混着放的。 */
            if MusicPlayer.shared.current == nil {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
            let p = try AVAudioPlayer(data: Self.silentWavData())
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            p.play()
            player = p
            running = true
            Realtime.shared.start()          // 顺手确保长连接是活的（切后台时可能刚回来）
        } catch {
            running = false
        }
    }

    /// 回到前台 / 退出登录 / 开始通话时调用：停掉保活，别白占着音频
    func stop() {
        guard running || player != nil else { return }
        player?.stop()
        player = nil
        running = false
        /* ⚠ 音乐在放的时候**别关音频会话**：一关，后台那条正在放的歌会跟着一起断
           （用户说「切到别的页面/退后台歌就停了」多半就是这里被关掉的）。
           只在没有音乐在放的时候才把会话让出去。 */
        if MusicPlayer.shared.current != nil { return }
        if !CallCenter.shared.phase.isBusy {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}
