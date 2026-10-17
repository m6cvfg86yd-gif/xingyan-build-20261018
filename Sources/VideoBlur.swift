import Foundation
import UIKit
import CoreImage
import Vision
import AVFoundation
import WebRTC
import TXLiteAVSDK_TRTC

/* ============================================================
   视频通话的「模糊背景」（对齐微信那一档）：人还是清楚的，背后的东西虚掉。

   做法：Vision 的人像分割拿一张遮罩 → 整帧高斯模糊 → 按遮罩把原帧的人贴回去。

   ⚠ 这个功能**只能「不生效」，绝不能把通话弄坏**：
     任何一步（取遮罩 / 模糊 / 合成 / 分配输出缓冲）失败，就返回 nil，
     调用方直接把原帧发出去，画面照旧、通话照旧。
   ⚠ 费电：每 3 帧才算一次遮罩（中间几帧复用），连续太慢会自己关掉并告诉用户。
   ============================================================ */

final class VideoBlur: NSObject, TRTCVideoFrameDelegate {
    static let shared = VideoBlur()

    /// 开关（通话里点那颗「模糊背景」按钮）
    var enabled = false
    /// 自动关掉时的一句提示（交给通话页弹给用户看）
    var onAutoOff: ((String) -> Void)?

    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var mask: CVPixelBuffer?
    private var maskSize = CGSize.zero
    private var tick = 0
    private var slowFrames = 0

    /// 一通电话结束：把缓存的遮罩清掉
    func reset() {
        lock.lock()
        mask = nil
        maskSize = .zero
        tick = 0
        slowFrames = 0
        lock.unlock()
    }

    /// 处理一帧（BGRA 的 PixelBuffer）；处理不了返回 nil（调用方照原样发出去）
    func process(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        guard enabled else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard w > 1, h > 1 else { return nil }
        let ext = CGRect(x: 0, y: 0, width: w, height: h)

        lock.lock()
        if mask == nil || tick % 3 == 0 {
            mask = personMask(src)
            maskSize = ext.size
        }
        tick &+= 1
        let m = mask
        lock.unlock()
        guard let m = m else { return nil }

        let ci = CIImage(cvPixelBuffer: src)
        /* 背景整帧模糊：**先缩一半再糊**，快得多（反正背景本来就是糊的），
           糊完再放大回原尺寸。 */
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        let half = ci.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        blur.setValue(half.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(18.0, forKey: kCIInputRadiusKey)
        guard let blurredHalf = blur.outputImage else { return nil }
        let blurred = blurredHalf
            .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(w) / 2, height: CGFloat(h) / 2))
            .transformed(by: CGAffineTransform(scaleX: 2, y: 2))
            .cropped(to: ext)

        /* 遮罩一般是缩小过的（Vision 出来的尺寸和原帧不一定一样），拉回原尺寸 */
        let maskCI = CIImage(cvPixelBuffer: m)
        let me = maskCI.extent
        guard me.width > 1, me.height > 1 else { return nil }
        let scaled = maskCI.transformed(by: CGAffineTransform(scaleX: ext.width / me.width,
                                                              y: ext.height / me.height))

        guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
        blend.setValue(ci, forKey: kCIInputImageKey)                    // 人：原帧
        blend.setValue(blurred, forKey: kCIInputBackgroundImageKey)     // 背景：糊过的
        blend.setValue(scaled, forKey: kCIInputMaskImageKey)
        guard let out = blend.outputImage, let dst = makeBuffer(w: w, h: h) else { return nil }
        ctx.render(out, to: dst, bounds: ext, colorSpace: CGColorSpaceCreateDeviceRGB())

        /* 太慢就自己关掉：通话流畅比这个效果重要得多 */
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        lock.lock()
        slowFrames = ms > 45 ? slowFrames + 1 : 0
        let tooSlow = slowFrames > 12
        lock.unlock()
        if tooSlow {
            enabled = false
            reset()
            onAutoOff?("手机有点吃力，模糊背景已自动关闭")
        }
        return dst
    }

    /// Vision 人像分割：白 = 人，黑 = 背景
    private func personMask(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .fast
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: src, orientation: .up, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        return req.results?.first?.pixelBuffer
    }

    private func makeBuffer(w: Int, h: Int) -> CVPixelBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        var buf: CVPixelBuffer?
        let r = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                    attrs as CFDictionary, &buf)
        return r == kCVReturnSuccess ? buf : nil
    }

    // MARK: - TRTC 的视频帧回调（群视频那条路走这里）

    func onProcessVideoFrame(_ srcFrame: TRTCVideoFrame, dstFrame: TRTCVideoFrame) -> UInt32 {
        guard enabled, let src = srcFrame.pixelBuffer, let out = process(src) else { return 0 }
        dstFrame.pixelBuffer = out
        return 0
    }
}

/* ---------------------------------------------------------------
   1 对 1 视频通话走的是 WebRTC 那条采集路：给采集器套一层代理，
   采集到的每一帧先过一遍 VideoBlur，再交给原来的 RTCVideoSource。
   --------------------------------------------------------------- */
final class BlurCapturer: NSObject, RTCVideoCapturerDelegate {
    private let inner: RTCVideoCapturerDelegate

    init(inner: RTCVideoCapturerDelegate) {
        self.inner = inner
        super.init()
    }

    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        guard VideoBlur.shared.enabled,
              let buf = frame.buffer as? RTCCVPixelBuffer,
              let out = VideoBlur.shared.process(buf.pixelBuffer) else {
            inner.capturer(capturer, didCapture: frame)
            return
        }
        let nb = RTCCVPixelBuffer(pixelBuffer: out)
        let nf = RTCVideoFrame(buffer: nb, rotation: frame.rotation, timeStampNs: frame.timeStampNs)
        inner.capturer(capturer, didCapture: nf)
    }
}
