import SwiftUI
import AVFoundation
import AVKit

/* ============================================================
   画中画（视频播放页左上角那颗按钮）

   AVPictureInPictureController 必须挂在**真正的 AVPlayerLayer** 上 ——
   所以播放页不再用只读的 PlayerLayerView，而用下面这个 PiPHostView：
   它把图层交出来，PiPBox 拿着这个图层去建控制器，点一下就能缩成小窗继续播。
   ============================================================ */

final class PiPBox: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    /// 这台设备支不支持画中画（模拟器/老设备上会是 false，按钮就置灰）
    @Published var supported = AVPictureInPictureController.isPictureInPictureSupported()
    /// 现在这一帧画面能不能进画中画（有画面、图层在屏上才为 true）
    @Published var possible = false
    /// 已经在画中画小窗里了
    @Published var active = false

    private var pip: AVPictureInPictureController?
    private var watch: NSKeyValueObservation?
    private weak var layer: AVPlayerLayer?

    /// 把一个播放图层交给画中画（同一个图层只建一次控制器）
    func attach(_ layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if self.layer === layer, pip != nil { return }
        watch?.invalidate(); watch = nil
        pip?.delegate = nil
        self.layer = layer
        let c = AVPictureInPictureController(playerLayer: layer)
        c?.delegate = self
        pip = c
        watch = c?.observe(\.isPictureInPicturePossible, options: [.new, .initial]) { [weak self] obj, _ in
            let v = obj.isPictureInPicturePossible
            DispatchQueue.main.async { self?.possible = v }
        }
    }

    /// 点一下：进出画中画
    func toggle() {
        guard let c = pip else { return }
        if c.isPictureInPictureActive { c.stopPictureInPicture(); return }
        guard c.isPictureInPicturePossible else { return }
        /* 画中画要有声音通道：拨到「播放」（静音键按下去也有声） */
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? s.setActive(true)
        c.startPictureInPicture()
    }

    func stop() { pip?.stopPictureInPicture() }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.active = true }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        DispatchQueue.main.async { self.active = false; self.possible = c.isPictureInPicturePossible }
    }

    func pictureInPictureController(_ c: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async { self.active = false; self.possible = c.isPictureInPicturePossible }
    }
}

final class PiPLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// 播放画面（图层同时交给画中画）
struct PiPHostView: UIViewRepresentable {
    let player: AVPlayer?
    let box: PiPBox

    func makeUIView(context: Context) -> PiPLayerUIView {
        let v = PiPLayerUIView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        box.attach(v.playerLayer)
        return v
    }

    func updateUIView(_ v: PiPLayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        box.attach(v.playerLayer)
    }
}
