import SwiftUI
import UIKit
import AVFoundation
import CoreImage
import Vision

/* ============================================================
   拍摄表情（微信那个）

   · **单独一个小相机**（全屏），不是直接调系统相机 —— 用户要求
   · 底下有一排「特效」，是**实时**加在取景画面上的（微信里也是边看边换）
   · 拍下来自动把背景抠掉（苹果 Vision 的前景分割，iOS 17+），
     和微信表情一样只留人；我们的上传是 JPEG（没有透明通道），
     所以抠完**铺一层白底**，看着就是微信那种"白底表情"
   · 拍完可以「重拍」或者「使用」，「使用」交回调用方（上传 + 加进我添加的表情）
   ============================================================ */

/// 一个特效：filter = 调色滤镜（CIFilter 名，空 = 不调色）；
/// face   = 人脸特效（会跟着脸动的贴纸：ears / crown / glasses / hearts / blush / sparkle）
struct StickerFx: Identifiable, Hashable {
    var id: String
    var name: String
    var filter: String = ""
    /// 滤镜参数（像素/点彩这类要"多大一格"）：0 = 用系统默认
    var scale: Double = 0
    var face: String = ""
    /// 是不是「人脸特效」那一类（界面分两个 tab 用）
    var isFace: Bool { !face.isEmpty }
}

/// 特效清单。第 0 项永远是「无特效」（照微信：无特效 / 特效 两个 tab）。
let stickerFxList: [StickerFx] = [
    StickerFx(id: "none", name: "无特效"),
    /* ---- 人脸特效（会跟着脸动，微信那种） ---- */
    StickerFx(id: "ears",    name: "猫耳朵", face: "ears"),
    StickerFx(id: "bunny",   name: "兔耳朵", face: "bunny"),
    StickerFx(id: "crown",   name: "皇冠",   face: "crown"),
    StickerFx(id: "glasses", name: "墨镜",   face: "glasses"),
    StickerFx(id: "hearts",  name: "爱心眼", face: "hearts"),
    StickerFx(id: "blush",   name: "腮红",   face: "blush"),
    StickerFx(id: "puppy",   name: "小狗",   face: "puppy"),
    StickerFx(id: "sparkle", name: "闪光",   face: "sparkle"),
    /* ---- 调色滤镜（顺手留着的，微信那页没有，我们当附赠） ---- */
    StickerFx(id: "clear",  name: "清透", filter: "CIPhotoEffectProcess"),
    StickerFx(id: "mono",   name: "黑白", filter: "CIPhotoEffectMono"),
    StickerFx(id: "retro",  name: "复古", filter: "CIPhotoEffectInstant"),
    StickerFx(id: "comic",  name: "漫画", filter: "CIComicEffect"),
    StickerFx(id: "sepia",  name: "怀旧", filter: "CISepiaTone"),
    /* ---- 像素风（用户要的「像素」）：整幅画面打成马赛克/像素块 ---- */
    StickerFx(id: "pixel",     name: "像素",     filter: "CIPixellate",           scale: 12),
    StickerFx(id: "pixelBig",  name: "大像素",   filter: "CIPixellate",           scale: 30),
    StickerFx(id: "hexPixel",  name: "六边像素", filter: "CIHexagonalPixellate",  scale: 16),
    StickerFx(id: "dots",      name: "点彩",     filter: "CIPointillize",         scale: 10)
]

/// 套一层特效：带 scale 的（像素/点彩）要把参数一起传进去，不然是系统默认那一档
func stickerApply(_ img: CIImage, _ fx: StickerFx) -> CIImage {
    guard !fx.filter.isEmpty else { return img }
    if fx.scale > 0 {
        /* 点彩那个滤镜的参数叫 radius，其它（像素/六边像素）叫 scale */
        let key = (fx.filter == "CIPointillize") ? kCIInputRadiusKey : kCIInputScaleKey
        return img.applyingFilter(fx.filter, parameters: [key: fx.scale])
    }
    return img.applyingFilter(fx.filter)
}

/// 「特效来自：××」那一行（微信写的是 WeChat Effect）
let stickerEffectSource = "星言 Effect"

/* ============================================================
   一张脸上关键点的位置表 —— 微信那种「贴纸黏在脸上」全靠它

   · 所有坐标都是**归一化**的（0…1），原点在**左上角**（和 UIKit 画图一个方向），
     所以预览那一层和拍下来的方图能直接按比例共用同一套数字
   · 五官由苹果官方的人脸关键点接口（VNDetectFaceLandmarksRequest）逐帧给出来，
     没给全就按人脸框估一份，贴纸不会突然跳走
   ============================================================ */
struct StickerFace: Equatable {
    /// 人脸框
    var box: CGRect = CGRect(x: 0.25, y: 0.16, width: 0.5, height: 0.5)
    /// 画面左边那只眼睛的中心
    var leftEye: CGPoint = CGPoint(x: 0.40, y: 0.37)
    /// 画面右边那只眼睛的中心
    var rightEye: CGPoint = CGPoint(x: 0.60, y: 0.37)
    /// 鼻头
    var nose: CGPoint = CGPoint(x: 0.50, y: 0.46)
    /// 嘴巴中心
    var mouth: CGPoint = CGPoint(x: 0.50, y: 0.56)
    /// 眉毛那一排的中间高度（额头的下沿）
    var browY: CGFloat = 0.31
    /// 脑袋歪了多少（弧度）：两眼连线相对水平线的夹角，0 = 正着
    var roll: CGFloat = 0
    /// 这一份是不是**真检到脸**了（没检到就不画贴纸，别让猫耳朵飘在墙上）
    var ok = false

    /// 两眼之间有多远 —— 贴纸的大小几乎都按它算：脸近贴纸大、脸远贴纸小
    var eyeDist: CGFloat { max(0.02, hypot(rightEye.x - leftEye.x, rightEye.y - leftEye.y)) }
    /// 两眼中间的鼻梁处（墨镜、皇冠这些以它为中心）
    var eyeMid: CGPoint { CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2) }

    /// 只拿到人脸框、五官没给全时，按框估一份（保证贴纸尺寸位置都合理）
    static func estimated(_ b: CGRect) -> StickerFace {
        var f = StickerFace()
        f.box = b
        f.leftEye  = CGPoint(x: b.minX + b.width * 0.30, y: b.minY + b.height * 0.42)
        f.rightEye = CGPoint(x: b.minX + b.width * 0.70, y: b.minY + b.height * 0.42)
        f.nose     = CGPoint(x: b.midX,               y: b.minY + b.height * 0.58)
        f.mouth    = CGPoint(x: b.midX,               y: b.minY + b.height * 0.74)
        f.browY    = b.minY + b.height * 0.34
        f.roll     = 0
        f.ok = true
        return f
    }

    /// 两份位置之间做一次平滑（每帧都直接换新位置的话贴纸会抖，微信那种"黏"的感觉靠这个）
    func mix(_ n: StickerFace, _ a: CGFloat) -> StickerFace {
        func lerp(_ x: CGPoint, _ y: CGPoint) -> CGPoint {
            CGPoint(x: x.x + (y.x - x.x) * a, y: x.y + (y.y - x.y) * a)
        }
        var o = self
        o.box = CGRect(x: box.minX + (n.box.minX - box.minX) * a,
                       y: box.minY + (n.box.minY - box.minY) * a,
                       width: box.width + (n.box.width - box.width) * a,
                       height: box.height + (n.box.height - box.height) * a)
        o.leftEye = lerp(leftEye, n.leftEye)
        o.rightEye = lerp(rightEye, n.rightEye)
        o.nose = lerp(nose, n.nose)
        o.mouth = lerp(mouth, n.mouth)
        o.browY = browY + (n.browY - browY) * a
        o.roll = roll + (n.roll - roll) * a
        o.ok = n.ok
        return o
    }
}

/// 小相机的采集/滤镜/抠图这一层（SwiftUI 外面那层只是壳）
/// 拍一张要用的一整套：在**同一帧**上算好的「方图 + 贴纸层 + 裁切位置 + 缩放」。
/// ⚠ 2026-10-17 用户：「拍摄表情拍完依旧没有带贴纸发出去」——
///   以前 snapshotParts 只回 base 和 overlay，**裁切位置是 applyOverlay 里再读一次
///   lastCI 现算的**：相机这时还在 30fps 跑，脸一动（或者脸一丢、退回画面居中），
///   裁切框就变了，贴纸却还按老框在画 → 直接画到方图外面，看着就是"拍完没有贴纸"。
///   现在四样东西一次性算好，快门之后相机再怎么动都不影响这一张。
struct StickerShot {
    var base: UIImage
    var overlay: UIImage?
    var cropX: CGFloat
    var cropY: CGFloat
    var scale: CGFloat
}

final class StickerCam: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "sticker.cam.queue")
    private let ctx = CIContext(options: nil)

    /// 实时预览（已经过特效这一层）
    @Published var frame: UIImage?
    /// 没有摄像头 / 权限被拒
    @Published var denied = false
    /// 当前特效序号（切换时下一帧就变）
    var fxIndex = 0
    /// 当前这张脸的关键点（归一化、左上角为原点）。
    /// 只在相机那条队列里用（界面用的是 faceOverlay 那张图），所以不用 @Published。
    private var face = StickerFace()
    /// 上一次真检到脸是什么时候：脸丢开先"忍"半秒再收贴纸，免得一闪一闪
    private var lastHit = Date.distantPast
    /// 平滑系数：越大跟得越紧、越小越稳（微信那种"跟得紧又不抖"大概就这个数）
    private let follow: CGFloat = 0.45
    /// 这个请求在慢机器上耗时偏长时隔帧找（宁可稍微钝一点也别掉帧）
    private var detectEvery = 1
    /// 人脸特效那一层（透明图，和取景画面同比例）—— 预览时直接盖在画面上
    @Published var faceOverlay: UIImage?
    /// 现在用的是不是前置（微信那一页右下角可以前后切）
    private(set) var usingFront = true

    private var lastCI: CIImage?
    private var started = false
    private var rendering = false
    private var frameNo = 0
    /* 这一帧要不要转 90°/180° 才"正"。
       ⚠ 不同机型 / 系统版本上，采集连接给的旋转是不一样的（iOS 17 的
       videoRotationAngle 和老的 videoOrientation 行为也有差别），照着一个写死的
       角度走，轻则取景像躺着的（用户说的「感觉镜头是错的」），重则 Vision 认不出脸
       （「拍不到人」）。所以这里**自己找一个能认到脸的方向**并记住：
       下面 findFace() 会依次试几个方向，谁认得到脸就用谁。 */
    private var fix: CGImagePropertyOrientation = .right
    /// 诊断用：连续多少帧没检到脸（只上报一次，别刷屏）
    private var missFrames = 0
    private var reportedMiss = false
    private var reportedHit = false

    func start() {
        guard !started else { return }
        started = true
        queue.async { [weak self] in self?.configure() }
    }

    func stop() {
        started = false
        queue.async { [weak self] in
            guard let s = self?.session else { return }
            if s.isRunning { s.stopRunning() }
        }
    }

    /// 前后摄像头切换（微信「拍摄表情」右下角那颗）
    func flip() {
        usingFront.toggle()
        /* 换了镜头：上一颗镜头检到的脸不算数了，清掉让它重新找一个能认到脸的方向
           （清的是相机队列那份状态，所以放到队列里去改） */
        faceOverlay = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.face = StickerFace()
            self.lastHit = Date.distantPast
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.commitConfiguration()
            self.configure()
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        let want: AVCaptureDevice.Position = usingFront ? .front : .back
        let pick = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: want)
        guard let dev = pick ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.denied = true }
            return
        }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) {
            session.addOutput(out)
            if let conn = out.connection(with: .video) {
                /* 竖屏 + 前置镜像（自拍要跟镜子一样，微信也是这样） */
                if #available(iOS 17.0, *) {
                    if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                } else {
                    conn.videoOrientation = .portrait
                }
                if conn.isVideoMirroringSupported { conn.isVideoMirrored = (dev.position == .front) }
            }
        }
        session.commitConfiguration()
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let raw = CIImage(cvPixelBuffer: buf)

        /* ① 在这一帧上找脸 + 找五官（顺便当"方向探针"，见 findFace）。
              **每一帧都找**：微信那种贴纸是逐帧跟着五官走的 —— 隔帧找的话，
              快速摇头时贴纸会明显落在脸后面（用户说的"不会跟脸"就是这个）。
              请求太慢的机器才自动退回隔帧。 */
        frameNo += 1
        var hit: (face: StickerFace, fix: CGImagePropertyOrientation)? = nil
        let runDetect = (frameNo % max(1, detectEvery) == 0)
        if runDetect {
            let t0 = CFAbsoluteTimeGetCurrent()
            hit = findFace(raw)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            detectEvery = ms > 20 ? 2 : 1
        }
        if let hit {
            fix = hit.fix
            /* ② 平滑一下：手抖和 Vision 自己的抖动都被吃掉，贴纸才"黏"在脸上 */
            face = face.ok ? face.mix(hit.face, follow) : hit.face
            lastHit = Date()
            missFrames = 0
            if !reportedHit {
                reportedHit = true
                CrashCatcher.note("拍摄表情", "检到脸了 fix=\(hit.fix.rawValue) 眼距=\(String(format: "%.3f", face.eyeDist)) 歪头=\(String(format: "%.2f", face.roll))")
            }
        } else if runDetect {
            missFrames += 1
            /* 脸丢开先"忍"半秒（抬手挡一下、转头一瞬间不该闪），真丢了才收贴纸 */
            if Date().timeIntervalSince(lastHit) > 0.6 { face.ok = false }
            if missFrames == 25, !reportedMiss {
                reportedMiss = true
                CrashCatcher.note("拍摄表情", "连续 25 次没检到脸（fix=\(fix.rawValue)，分辨率 \(Int(raw.extent.width))x\(Int(raw.extent.height))）")
            }
        }

        var img = oriented(raw, fix)
        let fx = stickerFxList[min(max(0, fxIndex), stickerFxList.count - 1)]
        img = stickerApply(img, fx)

        /* ③ 人脸特效那一层：按**这一帧的五官位置**重画 ——
              所以贴纸会跟着脸平移、随脸远近缩放、跟着歪头一起转 */
        var over: UIImage? = nil
        if fx.isFace, face.ok {
            over = makeFaceOverlay(fx.face, frameSize: img.extent.size, face: face)
        }
        lastCI = img
        if let over {
            DispatchQueue.main.async { self.faceOverlay = over }
        } else if faceOverlay != nil {
            DispatchQueue.main.async { self.faceOverlay = nil }
        }
        guard !rendering else { return }
        rendering = true
        let ui = render(img)
        DispatchQueue.main.async {
            if let ui { self.frame = ui }
            self.rendering = false
        }
    }

    /// 拍一张：取**当前这一帧**（带滤镜）裁成方图，并把人脸特效那一层单独交出去。
    ///
    /// ⚠ 2026-10-16 用户：「拍摄相机已经跟脸了但是拍摄完还是没有带贴纸的」。
    /// 原因是合成的**顺序**：以前是「先把贴纸贴到照片上 → 再抠背景」，
    /// 而抠背景（Vision 前景分割）只认"人"这一整块 —— 猫耳朵、皇冠、闪光
    /// 这些悬在头上的贴纸不属于前景，被那一刀当成背景**整个切掉了**。
    /// 现在拆成两步：先抠人（cutout），抠完再把贴纸层贴回去（applyOverlay），
    /// 贴纸就一定在了。
    func snapshotParts() -> StickerShot? {
        guard let ci = lastCI else { return nil }
        let rect = cropRect(ci)
        let square = ci.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        guard let base = render(square) else { return nil }
        /* CI 原点在左下 → 换算成"离方图顶边多少"（UIKit 画图是从左上起算） */
        let cropY = ci.extent.height - rect.maxY
        let fx = stickerFxList[min(max(0, fxIndex), stickerFxList.count - 1)]
        guard fx.isFace, let over = faceOverlay, over.size.width > 1 else {
            return StickerShot(base: base, overlay: nil,
                               cropX: rect.minX, cropY: cropY, scale: 1)
        }
        return StickerShot(base: base, overlay: over,
                           cropX: rect.minX, cropY: cropY,
                           scale: max(0.01, ci.extent.width / over.size.width))
    }

    /// 把贴纸那一层按**拍那一刻**的裁切位置贴到方图上（抠完背景之后再调它）
    func applyOverlay(_ p: StickerShot, cut: UIImage) -> UIImage {
        guard let over = p.overlay else { return cut }
        let cropX = p.cropX
        let cropY = p.cropY
        let s = p.scale
        /* ⚠ 2026-10-16 用户：「表情相机拍出去的依然不带贴纸」。
           贴纸那一层是**整帧**尺寸（竖屏就是 270×480 这种），
           而这里以前 width / height **都用了裁切框的边长**（正方形）——
           等于把整帧贴纸硬压成正方形：纵向位置被压缩 1.78 倍、还拉变形，
           脸一偏，皇冠/猫耳就落到裁切框外面去了，看着就是"拍完没有贴纸"。
           现在按整帧的宽高比画，位置和取景预览里**完全一致**。 */
        let r = UIGraphicsImageRenderer(size: cut.size)
        return r.image { c in
            cut.draw(in: CGRect(origin: .zero, size: cut.size))
            over.draw(in: CGRect(x: -cropX / s, y: -cropY / s,
                                 width: over.size.width / s, height: over.size.height / s))
        }
    }

    /// 老接口（别处还在用）：直接给合成好的图
    func snapshot() -> UIImage? {
        guard let p = snapshotParts() else { return nil }
        return applyOverlay(p, cut: p.base)
    }

    /// 相册那条路：给一张**静图**现检一次脸、画出贴纸层。
    /// （以前相册只套调色滤镜，选了猫耳/皇冠也没用 —— 顺手补上）
    func faceOverlayForStill(_ img: UIImage, fx: StickerFx) -> UIImage? {
        guard fx.isFace, let ci = CIImage(image: img) else { return nil }
        guard let f = faceIn(ci) else { return nil }
        return makeFaceOverlay(fx.face, frameSize: ci.extent.size, face: f)
    }

    /* ---------------- 人脸特效：检测 + 画那一层 ---------------- */

    /// 按 EXIF 方向转一下（.up 就是原样）
    private func oriented(_ img: CIImage, _ o: CGImagePropertyOrientation) -> CIImage {
        o == .up ? img : img.oriented(o)
    }

    /// 这一帧该转哪个方向 + 脸上的五官在哪？**拿人脸当探针**：
    /// 先试上次记住的那个方向；没认到脸就把另外几个方向也挨个试一遍
    /// （只在这帧上试、而且缩到 480 再检，很快）。谁认到脸就用谁并记下来。
    /// 一个方向都认不到（屋里没人 / 太暗）：保住上次记住的方向。
    private func findFace(_ raw: CIImage) -> (face: StickerFace, fix: CGImagePropertyOrientation)? {
        var seen = Set<UInt32>()
        let all: [CGImagePropertyOrientation] = [fix, .up, .right, .left, .down].filter { o in
            if seen.contains(o.rawValue) { return false }
            seen.insert(o.rawValue)
            return true
        }
        /* 已经认到过人：只走记住的那个方向（省性能）；还没认到过：多试几个 */
        let tries: [CGImagePropertyOrientation] = face.ok ? [fix] : all
        for o in tries {
            if let f = faceIn(oriented(raw, o)) { return (face: f, fix: o) }
        }
        return nil
    }

    /// 找脸 + 找五官（苹果官方的人脸关键点接口 VNDetectFaceLandmarksRequest）：
    /// Vision 给的是「左下角为原点」的归一化坐标，这里立刻翻成**左上角为原点**
    /// （UIKit 画图那个方向），后面画贴纸就不用再翻来翻去。
    private func faceIn(_ img: CIImage) -> StickerFace? {
        /* 缩到 640 再检：只要归一化坐标，缩放不影响结果，但快很多。
           以前写 480，小一点的脸会检不出来（用户反馈"特效不追脸"）。 */
        let e = img.extent
        let long = max(e.width, e.height)
        var probe = img
        if long > 900 { probe = img.transformed(by: CGAffineTransform(scaleX: 640 / long, y: 640 / long)) }
        let req = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(ciImage: probe, orientation: .up, options: [:])
        guard (try? handler.perform([req])) != nil, let list = req.results, !list.isEmpty else { return nil }
        /* 画面里好几个人：认最大的那张（自拍里就是自己） */
        guard let f = list.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else { return nil }
        let b = f.boundingBox
        /* 太小的当成误检（背景里的路人甲）——只认宽度 ≥ 6% 的 */
        if b.width < 0.06 { return nil }
        var out = StickerFace.estimated(flipRect(b))
        /* 五官：Vision 给的点是**相对人脸框**的归一化坐标，重心就是这一处的位置 */
        if let lm = f.landmarks {
            if let p = lm.leftEye?.normalizedPoints, !p.isEmpty { out.leftEye = imagePoint(p, b) }
            if let p = lm.rightEye?.normalizedPoints, !p.isEmpty { out.rightEye = imagePoint(p, b) }
            if let p = lm.nose?.normalizedPoints, !p.isEmpty { out.nose = imagePoint(p, b) }
            if let p = lm.outerLips?.normalizedPoints, !p.isEmpty { out.mouth = imagePoint(p, b) }
            if let p = lm.leftEyebrow?.normalizedPoints, let q = lm.rightEyebrow?.normalizedPoints,
               !p.isEmpty, !q.isEmpty {
                out.browY = (imagePoint(p, b).y + imagePoint(q, b).y) / 2
            }
        }
        /* 脑袋歪了多少：两眼连线的倾角（贴纸要跟着一起转） */
        out.roll = atan2(out.rightEye.y - out.leftEye.y, out.rightEye.x - out.leftEye.x)
        return out
    }

    /// Vision 的框（左下角为原点）→ UIKit 的框（左上角为原点）
    private func flipRect(_ b: CGRect) -> CGRect {
        CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
    }

    /// 一串关键点（**相对人脸框**的归一化坐标、左下角为原点）
    /// → 它们的重心（整幅画面、左上角为原点）
    private func imagePoint(_ pts: [CGPoint], _ b: CGRect) -> CGPoint {
        var x: CGFloat = 0, y: CGFloat = 0
        for p in pts { x += p.x; y += p.y }
        let n = CGFloat(max(1, pts.count))
        return CGPoint(x: b.minX + (x / n) * b.width, y: 1 - (b.minY + (y / n) * b.height))
    }

    /// 画人脸特效那一层（小一号画，省性能；反正预览和方图都会等比缩放）。
    /// 以前是"按人脸框贴一张正着的图" —— 人一歪、一近一远，贴纸就对不上；
    /// 现在是按**五官**摆位、按**歪头角度**旋转，所以是真的跟着脸走。
    private func makeFaceOverlay(_ kind: String, frameSize: CGSize, face: StickerFace) -> UIImage? {
        guard frameSize.width > 1, frameSize.height > 1, face.ok else { return nil }
        let long = max(frameSize.width, frameSize.height)
        let s = min(1, 480 / long)
        let size = CGSize(width: frameSize.width * s, height: frameSize.height * s)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.opaque = false
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { c in
            drawStickerFace(kind, face, size, c.cgContext)
        }
    }

    /// 把背景抠掉（微信拍摄表情那样只留人）：
    /// iOS 17 起苹果有现成的前景分割；不支持或失败就原图返回。
    /// 抠完铺白底 —— 上传是 JPEG，没有透明通道，白底看着就是微信那种表情。
    func cutout(_ image: UIImage) -> UIImage {
        guard #available(iOS 17.0, *), let cg = image.cgImage else { return image }
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([req])) != nil,
              let res = req.results?.first,
              let mask = try? res.generateScaledMaskForImage(forInstances: res.allInstances, from: handler),
              let blend = CIFilter(name: "CIBlendWithMask") else { return image }
        let base = CIImage(cgImage: cg)
        blend.setValue(base, forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: .white).cropped(to: base.extent),
                       forKey: kCIInputBackgroundImageKey)
        blend.setValue(CIImage(cvPixelBuffer: mask), forKey: kCIInputMaskImageKey)
        guard let out = blend.outputImage,
              let cgOut = ctx.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: cgOut)
    }

    /// 要裁的那块正方形：**检到脸就以脸为中心**（竖屏自拍的脸偏上，
    /// 按正中裁经常把整张脸切掉 —— 用户说的"拍不到人"），没检到就居中。
    private func cropRect(_ img: CIImage) -> CGRect {
        let e = img.extent
        let side = min(e.width, e.height)
        var x = e.midX - side / 2
        var y = e.midY - side / 2
        if face.ok {
            let b = face.box
            let cx = e.minX + b.midX * e.width
            /* 关键点是「左上角为原点」，CI 这张图是「左下角为原点」，y 要翻一下 */
            let cy = e.maxY - b.midY * e.height
            x = cx - side / 2
            y = cy - side / 2
        }
        x = min(max(e.minX, x), e.maxX - side)
        y = min(max(e.minY, y), e.maxY - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    private func cropSquare(_ img: CIImage) -> CIImage {
        let rect = cropRect(img)
        return img.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    private func render(_ img: CIImage) -> UIImage? {
        guard let cg = ctx.createCGImage(img, from: img.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/* ============================================================ 界面 */

struct StickerCamera: View {
    // 说明见文件末尾的两个小工具
    /// 拍好（抠完）交回去：调用方负责上传 + 加进「我添加的表情」
    var onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cam = StickerCam()
    /// 当前选中的特效（下标进 stickerFxList；0 = 无特效）
    @State private var fx = 0
    /// 上面那两个 tab：0 = 无特效，1 = 特效（照微信那一页）
    @State private var fxTab = 0
    @State private var shot: UIImage?
    @State private var busy = false
    @State private var flash = false
    /// 从相册选一张当表情
    @State private var showAlbum = false

    /// 现在选中的那一条
    private var fxNow: StickerFx { stickerFxList[min(max(0, fx), stickerFxList.count - 1)] }

    var body: some View {
        /* 微信「拍摄表情」的样子：**一小块相机窗口**（不是全屏取景）——
           上面标题 + 提示，中间那块小相机，下面特效 tab + 那排特效，
           最底下相册 / 快门 / 前后翻转。 */
        GeometryReader { geo in
            let camW = min(geo.size.width - 96, 250)
            let camH = camW * 4 / 3

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                HStack {
                    Button { cam.stop(); dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text(Tr("拍摄表情"))
                        .font(pf(16, .medium))
                        .foregroundColor(.white)
                    Spacer()
                    Color.clear.frame(width: 34, height: 34)
                }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)

                /* 微信那句提示就挂在标题下面 */
                if shot == nil {
                    Text(Tr("表情将会上传保存，在其他设备也可查看"))
                        .font(pf(12.5))
                        .foregroundColor(.white.opacity(0.62))
                        .padding(.top, 6)
                }

                Spacer(minLength: 10)

                /* ---- 一小块相机窗口 ---- */
                ZStack {
                    if let shot {
                        Image(uiImage: shot)
                            .resizable()
                            .scaledToFill()
                    } else if cam.denied {
                        VStack(spacing: 8) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.white.opacity(0.7))
                            Text(Tr("打不开相机，去系统设置里给星言开一下相机权限"))
                                .font(pf(12.5))
                                .foregroundColor(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 18)
                        }
                    } else {
                        StickerPreview(cam: cam)
                    }
                }
                .frame(width: camW, height: camH)
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1))

                Spacer(minLength: 10)

                if shot == nil {
                    effectRow
                    shutterRow
                } else {
                    HStack(spacing: 12) {
                        Button { withAnimation(.easeOut(duration: 0.15)) { shot = nil } } label: {
                            Text(Tr("重拍"))
                                .font(pf(15, .medium))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Capsule().fill(Color.white.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        Button {
                            if let s = shot { onDone(s) }
                            cam.stop()
                            dismiss()
                        } label: {
                            Text(Tr("使用"))
                                .font(pf(15, .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Capsule().fill(C.green))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 26)
                }
                }

                /* 白闪一下（微信按快门那一下也有） */
                if flash {
                    Color.white.opacity(0.85).ignoresSafeArea()
                }
            }
        }
        .statusBarHidden(true)
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
        .sheet(isPresented: $showAlbum) {
            PhotoPicker { img in
                /* 相册来的图：裁成正方形 + 套当前那层调色（不抠背景，人家选的就是想要的图）。
                   选完还是走「重拍 / 使用」这一步，和拍的一样。 */
                let sq = stickerSquare(img)
                let fxPick = fxNow
                DispatchQueue.global(qos: .userInitiated).async {
                    var out = stickerEffect(sq, fxPick)
                    /* 2026-10-17：相册这条路过完滤镜**还要把人脸特效贴上去**——
                       以前只套调色滤镜，选了猫耳/皇冠在相册照片上一点反应都没有。 */
                    if fxPick.isFace, let over = cam.faceOverlayForStill(sq, fx: fxPick) {
                        out = stickerCompose(out, over)
                    }
                    DispatchQueue.main.async { shot = out }
                }
            }
        }
    }

    /// 下面那排「特效」：点一下实时换
    private var effectRow: some View {
        VStack(spacing: 8) {
            /* 照微信：左边两个 tab「无特效 / 特效」 */
            HStack(spacing: 8) {
                tabChip(Tr("无特效"), 0)
                tabChip(Tr("特效"), 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    let list = fxTab == 0 ? Array(stickerFxList.prefix(1)) : Array(stickerFxList.dropFirst())
                    ForEach(list) { item in
                        let i = stickerFxList.firstIndex(of: item) ?? 0
                        Button {
                            fx = i
                            cam.fxIndex = i
                        } label: {
                            /* 微信那一排是**圆的预览图 + 名字**，点哪个取景画面里立刻换 */
                            VStack(spacing: 5) {
                                ZStack {
                                    Image(uiImage: StickerThumbs.shared.get(item))
                                        .resizable()
                                        .frame(width: 54, height: 54)
                                        .clipShape(Circle())
                                    Circle()
                                        .stroke(fx == i ? Color.white : Color.white.opacity(0.16),
                                                lineWidth: fx == i ? 2.4 : 1)
                                        .frame(width: 54, height: 54)
                                }
                                Text(Tr(item.name))
                                    .font(pf(11, fx == i ? .semibold : .regular))
                                    .foregroundColor(fx == i ? .white : .white.opacity(0.66))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }

            /* 微信那一行小字：「特效来自：WeChat Effect」——我们写自己的名字 */
            HStack(spacing: 6) {
                Text(Tr("特效来自：") + stickerEffectSource)
                    .font(pf(11.5))
                    .foregroundColor(.white.opacity(0.62))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 14)
    }

    /// 「无特效 / 特效」那颗小胶囊
    private func tabChip(_ title: String, _ idx: Int) -> some View {
        Button {
            fxTab = idx
            if idx == 0 {
                fx = 0
                cam.fxIndex = 0
            } else if fx == 0 {
                fx = 1
                cam.fxIndex = 1
            }
        } label: {
            Text(title)
                .font(pf(12.5, fxTab == idx ? .semibold : .regular))
                .foregroundColor(fxTab == idx ? .white : .white.opacity(0.65))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(fxTab == idx
                                           ? Color.white.opacity(0.28)
                                           : Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }

    /// 快门：一颗大圆钮（微信也是这个位置）
    private var shutterRow: some View {
        HStack(spacing: 0) {
            /* 左边：从相册选一张当表情（微信这一格就是相册） */
            Button { showAlbum = true } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Button { shoot() } label: {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.9), lineWidth: 4)
                        .frame(width: 74, height: 74)
                    Circle().fill(Color.white)
                        .frame(width: 58, height: 58)
                    if busy { ProgressView().tint(.black) }
                }
            }
            .buttonStyle(.plain)
            .disabled(busy)

            /* 右边：前后摄像头切换 */
            Button { cam.flip() } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 26)
    }

    private func shoot() {
        guard !busy, let parts = cam.snapshotParts() else { return }
        busy = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeIn(duration: 0.12)) { flash = false }
        }
        /* 2026-10-17 用户又报「拍完依旧没有带贴纸」：快门这一下把"贴纸层到底有没有、
           当前是哪个特效"记进后台日志 —— 以后一看日志就知道是没检到脸（层就是空的），
           还是后面合成那一步丢了。 */
        CrashCatcher.note("拍摄表情", "快门：贴纸层=\(parts.overlay == nil ? "无" : "有")｜特效=\(fxNow.name)")
        DispatchQueue.global(qos: .userInitiated).async {
            /* 顺序很重要：**先抠人、再把贴纸贴回去**（反了的话贴纸会被前景遮罩切掉，
               用户看到的就变成"拍完没有贴纸"）。裁切位置用的是**快门那一刻**存下来的，
               相机后面再怎么动都不影响这一张。 */
            let cut = cam.cutout(parts.base)
            let out = cam.applyOverlay(parts, cut: cut)
            DispatchQueue.main.async {
                shot = out
                busy = false
            }
        }
    }
}

/* ---------- 两个小工具（相册选图那条路用） ---------- */

/* ---------- 人脸特效怎么画（f = 人脸框，坐标跟 g 一致；左上角为原点） ---------- */

/// 一颗爱心（用于「爱心眼」）
private func stickerHeart(_ r: CGRect, _ g: CGContext) {
    let w = r.width, h = r.height
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.midX, y: r.maxY))
    p.addCurve(to: CGPoint(x: r.minX, y: r.minY + h * 0.32),
               control1: CGPoint(x: r.midX - w * 0.58, y: r.maxY - h * 0.28),
               control2: CGPoint(x: r.minX, y: r.midY))
    p.addCurve(to: CGPoint(x: r.midX, y: r.minY + h * 0.30),
               control1: CGPoint(x: r.minX + w * 0.16, y: r.minY - h * 0.06),
               control2: CGPoint(x: r.midX - w * 0.18, y: r.minY))
    p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + h * 0.32),
               control1: CGPoint(x: r.midX + w * 0.18, y: r.minY),
               control2: CGPoint(x: r.maxX - w * 0.16, y: r.minY - h * 0.06))
    p.addCurve(to: CGPoint(x: r.midX, y: r.maxY),
               control1: CGPoint(x: r.maxX, y: r.midY),
               control2: CGPoint(x: r.midX + w * 0.58, y: r.maxY - h * 0.28))
    p.closeSubpath()
    g.addPath(p)
    g.fillPath()
}

/// 一颗四角星（用于「闪光」）
private func stickerStar(_ c: CGPoint, _ r: CGFloat, _ g: CGContext) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y - r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + r * 0.18, y: c.y - r * 0.18))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + r * 0.18, y: c.y + r * 0.18))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - r * 0.18, y: c.y + r * 0.18))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - r * 0.18, y: c.y - r * 0.18))
    p.closeSubpath()
    g.addPath(p)
    g.fillPath()
}

/// 把某一种人脸特效画出来。
/// · face 里是**归一化**的五官位置（左上角为原点），size 是这张画布多大
/// · 贴纸一律**按眼距定尺寸、按五官定位、按歪头角度旋转** —— 这就是"跟脸"的关键：
///   人和镜头离远一点贴纸跟着变小、脸往左移贴纸往左走、歪头猫耳朵也跟着歪
func drawStickerFace(_ kind: String, _ face: StickerFace, _ size: CGSize, _ g: CGContext) {
    let W = size.width, H = size.height
    guard W > 8, H > 8 else { return }
    /* 人脸框 + 五官，全部换算成这张画布上的像素 */
    let box = CGRect(x: face.box.minX * W, y: face.box.minY * H,
                     width: face.box.width * W, height: face.box.height * H)
    guard box.width > 6, box.height > 6 else { return }
    func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * W, y: p.y * H) }
    let le = px(face.leftEye)
    let re = px(face.rightEye)
    let nm = px(face.nose)
    let mid = CGPoint(x: (le.x + re.x) / 2, y: (le.y + re.y) / 2)
    let eyeD = max(6, hypot(re.x - le.x, re.y - le.y))
    let hw = box.width, hh = box.height

    /* 以某个点为轴，把里面的东西跟着脑袋一起转（歪头贴纸不歪，就是"假"的来源） */
    func spun(_ pivot: CGPoint, _ body: () -> Void) {
        g.saveGState()
        g.translateBy(x: pivot.x, y: pivot.y)
        g.rotate(by: face.roll)
        g.translateBy(x: -pivot.x, y: -pivot.y)
        body()
        g.restoreGState()
    }

    g.saveGState()
    defer { g.restoreGState() }
    switch kind {
    case "ears":
        /* 猫耳朵：头顶左右各一只（外面深灰、里面一撮粉） */
        let ew = hw * 0.36, eh = hh * 0.40
        spun(mid) {
            for dx in [box.minX + hw * 0.02, box.maxX - hw * 0.02 - ew] {
                let base = box.minY + hh * 0.12
                let p = CGMutablePath()
                p.move(to: CGPoint(x: dx, y: base))
                p.addLine(to: CGPoint(x: dx + ew / 2, y: base - eh))
                p.addLine(to: CGPoint(x: dx + ew, y: base))
                p.closeSubpath()
                g.setFillColor(UIColor(red: 0.19, green: 0.17, blue: 0.21, alpha: 0.96).cgColor)
                g.addPath(p); g.fillPath()
                let q = CGMutablePath()
                q.move(to: CGPoint(x: dx + ew * 0.28, y: base - eh * 0.08))
                q.addLine(to: CGPoint(x: dx + ew / 2, y: base - eh * 0.74))
                q.addLine(to: CGPoint(x: dx + ew * 0.72, y: base - eh * 0.08))
                q.closeSubpath()
                g.setFillColor(UIColor(red: 1, green: 0.62, blue: 0.72, alpha: 0.95).cgColor)
                g.addPath(q); g.fillPath()
            }
        }
    case "bunny":
        /* 兔耳朵：头顶两只长耳朵（白毛 + 粉内耳） */
        let ew = hw * 0.22, eh = hh * 0.80
        spun(mid) {
            for dx in [box.minX + hw * 0.17, box.maxX - hw * 0.17 - ew] {
                let r = CGRect(x: dx, y: box.minY + hh * 0.20 - eh, width: ew, height: eh)
                g.setFillColor(UIColor(white: 0.98, alpha: 0.96).cgColor)
                g.fillEllipse(in: r)
                let inner = CGRect(x: r.minX + ew * 0.26, y: r.minY + eh * 0.12,
                                   width: ew * 0.48, height: eh * 0.74)
                g.setFillColor(UIColor(red: 1, green: 0.72, blue: 0.80, alpha: 0.92).cgColor)
                g.fillEllipse(in: inner)
            }
        }
    case "crown":
        /* 皇冠：头顶一顶金色小冠 + 三颗白珠（宽度按眼距走，脸大脸小都合适） */
        let cw = eyeD * 3.1, ch = eyeD * 1.00
        let x = mid.x - cw / 2
        let y = box.minY - ch * 0.70
        spun(mid) {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: x, y: y + ch))
            p.addLine(to: CGPoint(x: x + cw * 0.12, y: y + ch * 0.22))
            p.addLine(to: CGPoint(x: x + cw * 0.30, y: y + ch * 0.78))
            p.addLine(to: CGPoint(x: x + cw * 0.50, y: y + ch * 0.14))
            p.addLine(to: CGPoint(x: x + cw * 0.70, y: y + ch * 0.78))
            p.addLine(to: CGPoint(x: x + cw * 0.88, y: y + ch * 0.22))
            p.addLine(to: CGPoint(x: x + cw, y: y + ch))
            p.closeSubpath()
            g.setFillColor(UIColor(red: 1.0, green: 0.80, blue: 0.20, alpha: 0.98).cgColor)
            g.addPath(p); g.fillPath()
            g.setFillColor(UIColor(red: 1, green: 1, blue: 1, alpha: 0.92).cgColor)
            for i in 0..<3 {
                let cx = x + cw * (0.14 + 0.36 * CGFloat(i))
                let d = max(3, eyeD * 0.16)
                g.fillEllipse(in: CGRect(x: cx - d / 2, y: y + ch * 0.82, width: d, height: d))
            }
        }
    case "glasses":
        /* 墨镜：**两只镜片分别压在两只眼睛上**（以前是一条横条，脸一歪就滑到腮帮子） */
        let lw = eyeD * 1.20, lh = eyeD * 0.90
        spun(mid) {
            g.setFillColor(UIColor.black.withAlphaComponent(0.88).cgColor)
            for c in [le, re] {
                let r = CGRect(x: c.x - lw / 2, y: c.y - lh / 2, width: lw, height: lh)
                let lens = CGPath(roundedRect: r, cornerWidth: lh * 0.42,
                                  cornerHeight: lh * 0.42, transform: nil)
                g.addPath(lens); g.fillPath()
            }
            /* 中间那道桥 */
            let bx = le.x + lw / 2 - lw * 0.10
            let bw = max(2, (re.x - lw / 2 + lw * 0.10) - bx)
            g.fill(CGRect(x: bx, y: mid.y - lh * 0.10, width: bw, height: lh * 0.20))
            /* 镜片高光，才像墨镜 */
            g.setFillColor(UIColor.white.withAlphaComponent(0.26).cgColor)
            for c in [le, re] {
                g.fill(CGRect(x: c.x - lw * 0.34, y: c.y - lh * 0.24, width: lw * 0.36, height: lh * 0.16))
            }
        }
    case "hearts":
        /* 爱心眼：两只红爱心**分别挂在两只眼睛上** */
        let d = eyeD * 1.00
        spun(mid) {
            g.setFillColor(UIColor(red: 1, green: 0.24, blue: 0.36, alpha: 0.95).cgColor)
            for c in [le, re] {
                stickerHeart(CGRect(x: c.x - d / 2, y: c.y - d * 0.44, width: d, height: d), g)
            }
        }
    case "blush":
        /* 腮红：眼睛下面往外的两块脸颊 */
        let rw = eyeD * 1.00, rh = eyeD * 0.56
        spun(mid) {
            g.setFillColor(UIColor(red: 1, green: 0.45, blue: 0.55, alpha: 0.42).cgColor)
            for c in [le, re] {
                let cx = c.x + (c.x < mid.x ? -eyeD * 0.30 : eyeD * 0.30)
                g.fillEllipse(in: CGRect(x: cx - rw / 2, y: c.y + eyeD * 0.42, width: rw, height: rh))
            }
        }
    case "puppy":
        /* 小狗：两片垂耳朵 + 一个黑鼻头（鼻头就压在**鼻子**那块，跟着鼻子动） */
        let ew = hw * 0.30, eh = hh * 0.56
        spun(mid) {
            g.setFillColor(UIColor(red: 0.45, green: 0.29, blue: 0.17, alpha: 0.95).cgColor)
            for dx in [box.minX - hw * 0.12, box.maxX - ew + hw * 0.12] {
                g.fillEllipse(in: CGRect(x: dx, y: box.minY + hh * 0.02, width: ew, height: eh))
            }
            let nd = eyeD * 0.58
            let nr = CGRect(x: nm.x - nd / 2, y: nm.y - nd * 0.60, width: nd, height: nd * 0.80)
            g.setFillColor(UIColor(red: 0.12, green: 0.10, blue: 0.11, alpha: 0.96).cgColor)
            let nose = CGPath(roundedRect: nr, cornerWidth: nd * 0.36,
                              cornerHeight: nd * 0.36, transform: nil)
            g.addPath(nose); g.fillPath()
        }
    case "sparkle":
        /* 闪光：脑袋周围几颗小星星 */
        spun(mid) {
            g.setFillColor(UIColor(red: 1, green: 0.95, blue: 0.55, alpha: 0.95).cgColor)
            let spots: [(CGFloat, CGFloat, CGFloat)] = [
                (0.02, 0.10, 0.30), (0.92, 0.06, 0.34), (1.02, 0.52, 0.26),
                (-0.04, 0.46, 0.32), (0.16, -0.10, 0.24), (0.78, -0.08, 0.30)
            ]
            for sp in spots {
                stickerStar(CGPoint(x: box.minX + hw * sp.0, y: box.minY + hh * sp.1),
                            max(3, eyeD * sp.2), g)
            }
        }
    default:
        break
    }
}

/// 特效那一排的**小圆图**：先画一张简笔"大头照"，再把这种特效按同一套算法套上去
/// （微信那一排也是效果预览图，不是干巴巴的文字）
func stickerFxThumb(_ item: StickerFx, _ side: CGFloat = 54) -> UIImage {
    let fmt = UIGraphicsImageRendererFormat.default()
    fmt.opaque = false
    fmt.scale = min(3, UIScreen.main.scale)
    let img = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { c in
        let g = c.cgContext
        let r = CGRect(x: 0.5, y: 0.5, width: side - 1, height: side - 1)
        g.setFillColor(UIColor(white: 0.24, alpha: 1).cgColor)
        g.fillEllipse(in: r)
        /* 简笔脸：自己画的，不用真照片 */
        let head = CGRect(x: side * 0.27, y: side * 0.22, width: side * 0.46, height: side * 0.60)
        g.setFillColor(UIColor(white: 0.93, alpha: 1).cgColor)
        g.fillEllipse(in: head)
        g.setFillColor(UIColor(white: 0.26, alpha: 1).cgColor)
        for ex in [head.minX + head.width * 0.31, head.minX + head.width * 0.69] {
            let d = side * 0.055
            g.fillEllipse(in: CGRect(x: ex - d / 2, y: head.minY + head.height * 0.44 - d / 2,
                                     width: d, height: d))
        }
        guard item.isFace else { return }
        g.saveGState()
        g.addEllipse(in: r)
        g.clip()
        drawStickerFace(item.face, StickerFace.estimated(head), CGSize(width: side, height: side), g)
        g.restoreGState()
    }
    /* 调色滤镜那一类：把这张小图过滤一遍就是它的效果 */
    return item.isFace ? img : stickerEffect(img, item)
}

/// 这一排小图做一次就存着（每次进这一页都重画十几张太浪费）
final class StickerThumbs {
    static let shared = StickerThumbs()
    private var cache: [String: UIImage] = [:]
    func get(_ item: StickerFx) -> UIImage {
        if let c = cache[item.id] { return c }
        let img = stickerFxThumb(item)
        cache[item.id] = img
        return img
    }
}

/// 裁成正方形（拍表情一律方形，和微信一样）
func stickerSquare(_ img: UIImage) -> UIImage {
    guard let cg = img.cgImage else { return img }
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    let side = min(w, h)
    guard side > 0 else { return img }
    let rect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
    guard let cropped = cg.cropping(to: rect) else { return img }
    return UIImage(cgImage: cropped, scale: img.scale, orientation: img.imageOrientation)
}

/// 给一张图套上特效（特效是"无特效" = 原图不动）
func stickerEffect(_ img: UIImage, _ fx: StickerFx) -> UIImage {
    guard !fx.filter.isEmpty, let ci = CIImage(image: img) else { return img }
    let out = stickerApply(ci, fx)
    let ctx = CIContext(options: nil)
    guard let cg = ctx.createCGImage(out, from: out.extent) else { return img }
    return UIImage(cgImage: cg, scale: img.scale, orientation: img.imageOrientation)
}

/// 只观察预览这一帧的子视图：30fps 刷新只重画它，不动整页
/// 把贴纸层整幅压到一张**同尺寸**的图上（相册那条路：图和人脸坐标是同一套，
/// 不需要相机那套裁切偏移）
func stickerCompose(_ base: UIImage, _ over: UIImage) -> UIImage {
    let r = UIGraphicsImageRenderer(size: base.size)
    return r.image { c in
        base.draw(in: CGRect(origin: .zero, size: base.size))
        over.draw(in: CGRect(origin: .zero, size: base.size))
    }
}

private struct StickerPreview: View {
    @ObservedObject var cam: StickerCam
    var body: some View {
        GeometryReader { g in
            ZStack {
                if let f = cam.frame {
                    Image(uiImage: f)
                        .resizable()
                        .scaledToFill()
                        .frame(width: g.size.width, height: g.size.height)
                        .clipped()
                } else {
                    Color.black
                }
                /* 人脸特效那一层：和画面同比例、同一个 scaledToFill，所以贴纸正好压在脸上 */
                if let o = cam.faceOverlay {
                    Image(uiImage: o)
                        .resizable()
                        .scaledToFill()
                        .frame(width: g.size.width, height: g.size.height)
                        .clipped()
                        .allowsHitTesting(false)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}
