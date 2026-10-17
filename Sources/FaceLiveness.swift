import SwiftUI
import AVFoundation
import Vision
import UIKit

/* ============================================================
   人脸核身（活体检测）—— 2026-10-15 按用户要求重做

   用户原话：「实名认证的人脸识别做的有点假，我要微信那种摇一摇转一转要真实的，
             并且是真实人脸捕捉」
   → 这一版做了两件关键事：
     ① **真实人脸捕捉**：前置摄像头（AVCaptureSession）出帧，每一帧都用 Vision
        （VNDetectFaceLandmarksRequest）在**本机**找人脸、量五官 —— 画面不上传、不保存。
     ② **真的要做动作才算过**：随机抽 3 个动作（眨眨眼 / 张张嘴 / 摇摇头 / 点点头），
        每一个都必须真的做到那一下才进下一档。
        ⚠ 旧版有个「9 秒没判断出来也放行」的兜底 —— 那个会让人干站着也能过（就是"假"的来源），
          这一版**删掉了**：超时只会重来这一档，绝不偷偷放行；
          多张脸 / 离太远 / 挡住 都会拦着不让过。

   页面照微信：中间圆形取景框 + 一圈微信绿进度弧 + 下面一行「请眨眨眼」这种提示 +
   做完打勾自动返回。
   ============================================================ */

/* ---------------------------------------------------------- 两页流程（照微信）
   2026-10-15 用户：「人脸识别你要学一下微信整套逻辑进去有2个页面的，不是直接进入的」
   → 以前点「开始人脸验证」**直接开摄像头**；现在照微信拆成两页：
     第 1 页：准备页（谁在验 / 注意事项 / 隐私说明 / 「开始识别」）
     第 2 页：活体检测页（摄像头 + 随机三个动作）
   ------------------------------------------------------------------ */

/// 人脸核身的入口页：**先说明，再进摄像头**（微信就是这样）
struct FaceVerifyFlowView: View {
    /// true = 通过
    let onDone: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 0 = 准备页 · 1 = 活体检测页
    @State private var step = 0

    var body: some View {
        if step == 0 {
            FacePrepView(
                onStart: { withAnimation(.easeOut(duration: 0.2)) { step = 1 } },
                onCancel: { onDone(false); dismiss() }
            )
        } else {
            FaceLivenessView { ok in onDone(ok) }
                .transition(.move(edge: .trailing))
        }
    }
}

/// 第 1 页：准备页（微信那一页长这样：上面一张示意图，下面几条注意事项，底下那颗绿色大按钮）
struct FacePrepView: View {
    var onStart: () -> Void
    var onCancel: () -> Void

    private let green = C.green        // 2026-10-17：跟主色走（ui.json: greenColor），不再写死微信绿

    private let tips: [(String, String)] = [
        ("light.max", "找个光线亮一点的地方"),
        ("eyeglasses", "摘下眼镜、口罩、帽子"),
        ("person.crop.circle", "把整张脸放进圆框里，别挡住"),
        ("hand.raised.fill", "跟着提示做几个动作：眨眼 / 张嘴 / 摇头 / 点头"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("人脸识别"), back: { onCancel() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    /* 示意图：一个圆框 + 脸 */
                    ZStack {
                        Circle().stroke(green.opacity(0.18), lineWidth: 6).frame(width: 168, height: 168)
                        Circle().fill(green.opacity(0.10)).frame(width: 150, height: 150)
                        Image(systemName: "faceid")
                            .font(.system(size: 72, weight: .light))
                            .foregroundColor(green)
                    }
                    .padding(.top, 22)

                    VStack(spacing: 6) {
                        Text(Tr("请本人操作")).font(pf(19, .semibold)).foregroundColor(C.label)
                        Text(Tr("为了确认是你本人，接下来会请你做几个动作"))
                            .font(pf(13.5)).foregroundColor(C.subLabel)
                            .multilineTextAlignment(.center).padding(.horizontal, 26)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tips.enumerated()), id: \.offset) { i, t in
                            HStack(spacing: 12) {
                                Image(systemName: t.0)
                                    .font(.system(size: 15))
                                    .foregroundColor(green)
                                    .frame(width: 26)
                                Text(Tr(t.1)).font(pf(14.5)).foregroundColor(C.label)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 50)
                            if i < tips.count - 1 { HairLine(inset: 54) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(C.cardBg))
                    .padding(.horizontal, 14)

                    Text(Tr("人脸信息只在这台手机的摄像头里做判定，不会上传、也不会保存。\n整个过程大概 10 秒。"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    Spacer().frame(height: 6)
                }
            }
            .background(C.pageBg)

            Button { onStart() } label: {
                Text(Tr("开始识别"))
                    .font(pf(17, .medium)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(green))
                    .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .padding(.bottom, max(12, L.safeBottom * 0.6))
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { onCancel() }
    }
}

/// 要用户做的动作
enum FaceAction: CaseIterable {
    case blink      // 眨眨眼
    case mouth      // 张张嘴
    case shake      // 摇摇头（左右都要甩到）
    case nod        // 点点头

    var title: String {
        switch self {
        case .blink: return "请眨眨眼"
        case .mouth: return "请张张嘴"
        case .shake: return "请摇摇头"
        case .nod:   return "请点点头"
        }
    }
    var hint: String {
        switch self {
        case .blink: return "慢慢眨一次眼，别挡住眼睛"
        case .mouth: return "嘴张开一点点就行"
        case .shake: return "头往左转一下、再往右转一下（幅度要看得出来）"
        case .nod:   return "头往下低一下、再抬起来（别只是往前凑）"
        }
    }
    var icon: String {
        switch self {
        case .blink: return "eye"
        case .mouth: return "mouth"
        case .shake: return "arrow.left.and.right"
        case .nod:   return "arrow.up.and.down"
        }
    }
}

struct FaceLivenessView: View {
    /// true = 通过
    let onDone: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 这一次要做的三个动作（第一个固定眨眼，另外两个随机）
    @State private var plan: [FaceAction] = []
    @State private var idx = 0
    @State private var hasFace = false
    @State private var tooMany = false
    @State private var tooFar = false
    @State private var hint = ""
    /// 只在「脸在框里」的时候累加，超时就重来这一档
    @State private var stall = 0
    @State private var done = false
    /// 环境检测：脸那块的平均亮度 / 对比度（太暗太亮提示；太平当反攻击信号）
    @State private var lightLuma = 0.5
    @State private var lightContrast = 0.2

    private let green = C.green        // 2026-10-17：跟主色走（ui.json: greenColor）

    private var cur: FaceAction? { idx < plan.count ? plan[idx] : nil }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("人脸识别"), back: {
                FaceLiveness.shared.stop()
                onDone(false)
                dismiss()
            })

            Spacer(minLength: 8)

            /* 圆形取景框 + 微信绿进度弧 */
            ZStack {
                Circle().fill(Color.black.opacity(0.88))
                FaceCameraPreview()
                    .clipShape(Circle())
                    .padding(3)
                    .opacity(hasFace && !tooMany ? 1 : 0.5)
                Circle().stroke(green.opacity(0.22), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: progress)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.25), radius: 8)
                } else if let a = cur {
                    Image(systemName: a.icon)
                        .font(.system(size: 30, weight: .light))
                        .foregroundColor(.white.opacity(hasFace ? 0.95 : 0.5))
                        .offset(y: 96)
                }
            }
            .frame(width: 262, height: 262)

            Text(Tr(title))
                .font(pf(18, .medium))
                .foregroundColor(C.label)
                .padding(.top, 22)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            Text(Tr(subTitle))
                .font(pf(13))
                .foregroundColor(C.subLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 8)

            /* 做动作的小图标条：做完一档变绿 */
            HStack(spacing: 10) {
                ForEach(Array(plan.enumerated()), id: \.offset) { i, a in
                    Image(systemName: i < idx ? "checkmark.circle.fill" : a.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(i < idx ? green : C.subLabel.opacity(0.5))
                }
            }
            .padding(.top, 16)

            Spacer(minLength: 16)

            Text(Tr("人脸信息只在这台手机的摄像头里做判定，不会上传也不会保存。"))
                .font(pf(12))
                .foregroundColor(C.subLabel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.bottom, 24)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack {
            FaceLiveness.shared.stop()
            onDone(false)
            dismiss()
        }
        .onAppear {
            if plan.isEmpty {
                /* 第一个固定眨眼（最容易做），另外两个随机 —— 每次进来动作都不一样 */
                let others = FaceAction.allCases.filter { $0 != .blink }.shuffled()
                plan = [.blink] + others.prefix(2)
            }
            stall = 0
            FaceLiveness.shared.start { ev in
                DispatchQueue.main.async { handle(ev) }
            }
        }
        .onDisappear { FaceLiveness.shared.stop() }
    }

    /* ---------------- 文案 / 进度 ---------------- */

    private var title: String {
        if done { return "验证通过" }
        if tooMany { return "画面里只能有一个人" }
        if !hasFace { return "请把脸放进圆框里" }
        if tooFar { return "靠近一点" }
        if lightLuma < 0.16 { return "这里太暗了" }
        if lightLuma > 0.90 { return "这里太亮了" }
        return cur?.title ?? "请正对屏幕"
    }

    private var subTitle: String {
        if done { return "" }
        if tooMany { return "把旁边的人移出画面，或者找一个安静的地方" }
        if !hasFace { return "光线亮一点、别挡住脸" }
        if tooFar { return "脸再靠近一点，占满中间这个框" }
        if lightLuma < 0.16 { return "找个亮一点的地方，别背光" }
        if lightLuma > 0.90 { return "光太强了：别对着灯或太阳，稍微挪一下" }
        if !FaceLiveness.shared.depthReady, lightContrast < 0.035 {
            return "画面太平了（像照片 / 屏幕）：请用**真人脸**、别对着屏幕或照片"
        }
        if !hint.isEmpty { return hint }
        return cur?.hint ?? ""
    }

    private var progress: CGFloat {
        guard !plan.isEmpty else { return 0.04 }
        if done { return 1 }
        return max(0.04, CGFloat(idx) / CGFloat(plan.count))
    }

    /* ---------------- 事件（都在主线程） ---------------- */

    private func handle(_ ev: FaceLiveness.Event) {
        switch ev {
        case .noFace:
            hasFace = false
            tooFar = false
        case .multi:
            tooMany = true
        case .face(let h, let luma, let contrast):
            tooMany = false
            hasFace = true
            tooFar = h < 0.30           // 脸太小 = 离太远，先让他靠近
            lightLuma = luma            // 环境检测：太暗 / 太亮
            lightContrast = contrast    // 太平（对比度很低）多半是屏幕 / 照片
        case .blink:
            if cur == .blink, hasFace, !tooFar { advance() }
        case .mouth:
            if cur == .mouth, hasFace, !tooFar { advance() }
        /* 摇头 / 点头：判定挪到 FaceLiveness 里了 ——
           那边要「时间窗内左右（上下）都甩够」才算一次真动作，并且已经把
           歪头（roll）和张嘴这两个"怪动作"从信号里剔掉，所以这边收到就是真的。 */
        case .shake:
            if cur == .shake, hasFace, !tooFar { advance() }
        case .nod:
            if cur == .nod, hasFace, !tooFar { advance() }
        case .tick:
            /* ⚠ 只在「脸在框里」的时候计时；超时 = **重来这一档**，绝不放行 */
            guard hasFace, !tooMany, !done else { return }
            stall += 1
            if stall == 4 { hint = "没看清，再来一次" }
            if stall >= 12 {
                resetStep()
                hint = "这次没看清：照着提示再做一次"
            }
        }
    }

    private func advance() {
        /* 用户要求「不要让 ai 图像过，要真实对比」：
           有深度这一路的机型上，**过之前先查深度**——平面（照片/屏幕/AI 图）
           的深度起伏几乎为 0，真人脸有几厘米。起伏太小就不让过，并说清原因。 */
        if FaceLiveness.shared.depthReady, let r = FaceLiveness.shared.depthRangeValue,
           r < 0.030, idx >= plan.count - 1 {
            hint = "看着像平面（照片 / 屏幕 / 生成的图）：请用**真人脸**、别对着屏幕或照片"
            stall = 6
            return
        }
        /* 太暗 / 太亮 / 太平都不让过（老机型没有深度，就用「太平」这一条兜一下反攻击） */
        if idx >= plan.count - 1 {
            if lightLuma < 0.16 || lightLuma > 0.90 {
                hint = "光线不合适：换个亮一点（或别太晃眼）的地方再来一次"
                stall = 6
                return
            }
            if !FaceLiveness.shared.depthReady, lightContrast < 0.035 {
                hint = "画面太平（像照片 / 屏幕）：请用真人脸，别对着屏幕或照片"
                stall = 6
                return
            }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        idx += 1
        resetStep()
        if idx >= plan.count {
            done = true
            FaceLiveness.shared.stop()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                onDone(true)
                dismiss()
            }
        }
    }

    private func resetStep() {
        stall = 0
        hint = ""
    }
}

/* ---------------------------------------------------------- 摄像头 + Vision */

/// 本机活体判定：只往外吐「有没有脸 / 眨眼 / 张嘴 / yaw / pitch」，
/// 画面和每一帧都留在本机（不上传、不落盘）。
final class FaceLiveness: NSObject {
    static let shared = FaceLiveness()

    enum Event {
        case noFace
        case multi
        /// 脸在画面里占多高（0~1，越大越近）+ 脸那块的平均亮度 / 对比度（环境检测用）
        case face(CGFloat, Double, Double)
        case blink
        case mouth
        /// 一次**真的**摇头：在时间窗内先甩到一边、再甩到另一边（都够幅度）
        case shake
        /// 一次**真的**点头：在时间窗内先低头、再抬头（都够幅度）
        case nod
        /// 半秒一次的心跳（界面用它算「这一档拖了多久」）
        case tick
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "chris.face.liveness")
    private var onEvent: ((Event) -> Void)?
    private var running = false
    private var lastFaceAt = Date()
    private var lastTick = Date()
    private var lastBlinkAt = Date.distantPast
    private var lastMouthAt = Date.distantPast
    private var lastMultiAt = Date.distantPast
    /// 眼睛开合基线 + 「闭过一下没有」（眨眼要求闭上再睁开）
    private var earSamples: [CGFloat] = []
    private var earClosed = false
    /// 张嘴要连着两帧都够大才算（单帧的抖动不算，皱眉/咧嘴也不至于算「张嘴」）
    private var mouthFrames = 0
    /* ---- 摇头 / 点头：**时间窗**里的偏转历史 ----
       2026-10-15 用户：「人脸识别做怪动作也会过」。
       以前只看"累计到过的最大/最小值"，慢慢晃、随便乱动都能攒够；
       现在把最近 1~2 秒的偏转都留着，**只有在这个窗口里两边都甩够**才算一次真动作。 */
    private var yawHist: [(t: Date, v: Double)] = []
    private var pitchHist: [(t: Date, v: Double)] = []
    /// 同一时间窗里人脸框的高度（点头时要求它基本不变 = 人没有前后移动）
    private var sizeHist: [(t: Date, v: Double)] = []
    /// 「正着脸」的 pitch 基线：取最近一段的**中位数**（做动作的那几下带不跑它）
    private var baseHist: [Double] = []
    private var pitchBase: Double = 0
    private var lastShakeAt = Date.distantPast
    private var lastNodAt = Date.distantPast
    /// 核身过程中留下的**一帧**（JPEG dataURL）——过了之后传给后台做比对
    var shot: String? = nil
    private let ci = CIContext()
    /// 有没有挂上深度这一路（TrueDepth 机型才有）
    private(set) var depthReady = false
    /// 最近一帧**脸那块区域**的深度起伏（米）：真人脸几厘米，平面图几乎为 0
    private(set) var depthRangeValue: Double? = nil

    var captureSession: AVCaptureSession { session }

    func start(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        shot = nil                      // 每次核身重新留一帧
        depthRangeValue = nil
        guard !running else { return }
        running = true
        queue.async { [weak self] in
            guard let self = self else { return }
            /* 每次核身都从零开始攒：上一次的偏转/眨眼历史绝不能带到这一次 */
            self.resetJudgement()
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            if self.session.inputs.isEmpty,
               let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
               let input = try? AVCaptureDeviceInput(device: dev),
               self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            let out = AVCaptureVideoDataOutput()
            out.alwaysDiscardsLateVideoFrames = true
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.setSampleBufferDelegate(self, queue: self.queue)
            if self.session.outputs.isEmpty, self.session.canAddOutput(out) {
                self.session.addOutput(out)
            }
            /* 2026-10-15 用户：「不要让 ai 图像过，要真实对比」——
               有 TrueDepth（原深感）的机型再挂一路**深度图**：
               真人脸在前后 3~8 厘米上有起伏（鼻尖↔脸颊），
               照片 / 屏幕 / AI 生成的图在深度上几乎是**一片平的** → 直接判不合格。 */
            if self.session.outputs.count < 2 {
                let dOut = AVCaptureDepthDataOutput()
                dOut.isFilteringEnabled = true
                dOut.setDelegate(self, callbackQueue: self.queue)
                if let dev = (self.session.inputs.first as? AVCaptureDeviceInput)?.device,
                   dev.activeFormat.supportedDepthDataFormats.count > 0,
                   self.session.canAddOutput(dOut) {
                    self.session.addOutput(dOut)
                    if let f = dev.activeFormat.supportedDepthDataFormats.last,
                       (dev.activeFormat.supportedDepthDataFormats.contains { $0 === dev.activeDepthDataFormat }) == false {
                        try? dev.lockForConfiguration()
                        dev.activeDepthDataFormat = f
                        dev.unlockForConfiguration()
                    }
                    self.depthReady = true
                }
            }
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        onEvent = nil
        guard running else { return }
        running = false
        queue.async { [weak self] in
            guard let self = self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func emit(_ ev: Event) { onEvent?(ev) }

    /// 把「判定用的那一堆历史」清干净（开一次核身调一次）
    private func resetJudgement() {
        yawHist.removeAll()
        pitchHist.removeAll()
        sizeHist.removeAll()
        baseHist.removeAll()
        pitchBase = 0
        lastShakeAt = Date.distantPast
        lastNodAt = Date.distantPast
        earSamples.removeAll()
        earClosed = false
        mouthFrames = 0
    }

    /// 眼睛的高度 / 宽度比（越大越睁着）。**两只眼分别给一份** ——
    /// 「眨眼」要求两只眼**一起**闭上：挤一只眼（wink）、挑眉、随手糊一下都不算。
    private func eyeRatios(_ obs: VNFaceObservation) -> (left: CGFloat?, right: CGFloat?) {
        func ratio(_ r: VNFaceLandmarkRegion2D?) -> CGFloat? {
            guard let r, r.pointCount > 4 else { return nil }
            let pts = r.normalizedPoints
            let xs = pts.map { CGFloat($0.x) }, ys = pts.map { CGFloat($0.y) }
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max() else { return nil }
            let w = maxX - minX
            guard w > 0.0001 else { return nil }
            return (maxY - minY) / w
        }
        guard let lm = obs.landmarks else { return (nil, nil) }
        return (ratio(lm.leftEye), ratio(lm.rightEye))
    }

    /// 嘴张开程度：内唇的高度 / 宽度（闭着嘴很小，张嘴明显变大）
    private func mouthOpen(_ obs: VNFaceObservation) -> CGFloat? {
        guard let lm = obs.landmarks, let m = (lm.innerLips ?? lm.outerLips), m.pointCount > 3 else { return nil }
        let pts = m.normalizedPoints
        let xs = pts.map { CGFloat($0.x) }, ys = pts.map { CGFloat($0.y) }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let w = maxX - minX
        guard w > 0.0001 else { return nil }
        return (maxY - minY) / w
    }

    /// 按五官算头姿（「摇头 / 点头」靠它，比 Vision 的 yaw/pitch 敏感得多）
    /// 脸那一块的平均亮度 / 对比度（0~1）：太暗太亮要提示；太平（对比度很低）多半是屏幕/照片
    private func lightQuality(_ pb: CVPixelBuffer, box: CGRect) -> (luma: Double, contrast: Double) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return (0.5, 0.2) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        /* Vision 的 box 原点在左下：换算成像素坐标，只取脸中间那一块 */
        let x0 = max(0, Int(Double(w) * Double(box.minX + box.width * 0.25)))
        let x1 = min(w, Int(Double(w) * Double(box.minX + box.width * 0.75)))
        let y0 = max(0, Int(Double(h) * (1 - Double(box.minY + box.height * 0.75))))
        let y1 = min(h, Int(Double(h) * (1 - Double(box.minY + box.height * 0.25))))
        guard x1 > x0 + 8, y1 > y0 + 8 else { return (0.5, 0.2) }
        var sum = 0.0, sum2 = 0.0, n = 0.0
        var y = y0
        while y < y1 {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            var x = x0
            while x < x1 {
                let b = Double(row[x * 4]), g = Double(row[x * 4 + 1]), r = Double(row[x * 4 + 2])
                let l = (0.114 * b + 0.587 * g + 0.299 * r) / 255.0
                sum += l; sum2 += l * l; n += 1
                x += 3
            }
            y += 3
        }
        guard n > 20 else { return (0.5, 0.2) }
        let mean = sum / n
        return (mean, max(0, sum2 / n - mean * mean).squareRoot())
    }

    /// 按五官算头姿。**摇头 / 点头** 就靠它。
    ///
    /// ⚠ 2026-10-15 用户：「人脸识别做怪动作也会过」。老写法有两个硬伤：
    ///   · 拿**人脸框内**的归一化坐标算比例：脸的 x 相对框宽、y 相对框高，
    ///     而人脸框是**轴对齐**的 —— 人一歪头（roll），框就变扁变宽，
    ///     这个比例跟着乱跳，于是「歪头 / 斜脑袋」被当成了摇头点头；
    ///   · pitch 用的是「眼睛→**嘴**」的竖直距离 —— 张嘴、皱嘴、吐舌头
    ///     都会让嘴巴重心往下跑，于是「做怪动作」也算点头。
    ///
    /// 现在三处都修了：
    ///   ① 五官先换算到**整幅画面**的坐标（x/y 同一把尺，不再随人脸框变形而变）；
    ///   ② 按两眼连线把脸**转正**（歪头被彻底消掉，不参与判断）；
    ///   ③ yaw = 鼻子相对两眼中点的水平偏移 ÷ 眼距；
    ///      pitch = 眼睛到**鼻子**的竖直距离 ÷ 眼距 —— 不碰嘴巴，张嘴不算点头。
    ///
    /// - Returns: yaw 正负表示往左右转、0 = 正对着；pitch 是绝对比例（正着脸约 0.4~0.7），要减基线
    private func poseProxy(_ obs: VNFaceObservation) -> (yaw: Double, pitch: Double)? {
        guard let lm = obs.landmarks,
              let nose = lm.nose, nose.pointCount > 0,
              let le = lm.leftEye, le.pointCount > 0,
              let re = lm.rightEye, re.pointCount > 0 else { return nil }
        let b = obs.boundingBox
        /* 人脸框内的归一化坐标 → 整幅画面的坐标（左下角为原点，和 Vision 一致） */
        func mid(_ r: VNFaceLandmarkRegion2D) -> CGPoint {
            let pts = r.normalizedPoints
            let x = pts.reduce(0.0) { $0 + Double($1.x) } / Double(max(1, pts.count))
            let y = pts.reduce(0.0) { $0 + Double($1.y) } / Double(max(1, pts.count))
            return CGPoint(x: b.minX + CGFloat(x) * b.width, y: b.minY + CGFloat(y) * b.height)
        }
        let lc = mid(le), rc = mid(re), nc = mid(nose)
        let dx = Double(rc.x - lc.x), dy = Double(rc.y - lc.y)
        let eyeDist = max(0.001, (dx * dx + dy * dy).squareRoot())
        /* 把脸"转正"：整张脸绕两眼中点转 -roll */
        let roll = atan2(dy, dx)
        let cr = cos(-roll), sr = sin(-roll)
        let ex = Double(lc.x + rc.x) / 2, ey = Double(lc.y + rc.y) / 2
        func upright(_ p: CGPoint) -> (x: Double, y: Double) {
            let vx = Double(p.x) - ex, vy = Double(p.y) - ey
            return (vx * cr - vy * sr, vx * sr + vy * cr)
        }
        let n = upright(nc)
        return (yaw: n.x / eyeDist, pitch: -n.y / eyeDist)
    }

    /// 收一帧头姿：只有**在时间窗内两边都甩够**才算一次真摇头 / 真点头。
    /// 慢慢晃、只往一边偏、随便乱动都攒不出来（这是"怪动作也能过"的正解）。
    /// - Parameter size: 这一帧人脸框的高度（判断脸有没有前后移动，见下面点头那条）
    private func trackPose(yaw: Double, pitch: Double, size: Double, now: Date) {
        /* ---- 摇头：最近 1.6 秒里，左右两边都甩到 ±0.10 以上（≈各转 15°），
               而且**每一边都得撑住至少两帧**（一帧的抖动不算） ---- */
        yawHist.append((now, yaw))
        while let f = yawHist.first, now.timeIntervalSince(f.t) > 1.6 { yawHist.removeFirst() }
        if yawHist.count > 150 { yawHist.removeFirst() }
        let yRight = yawHist.filter { $0.v > 0.09 }.count
        let yLeft = yawHist.filter { $0.v < -0.09 }.count
        if yRight >= 2, yLeft >= 2, now.timeIntervalSince(lastShakeAt) > 1.0 {
            lastShakeAt = now
            yawHist.removeAll()
            emit(.shake)
        }

        /* ---- 点头：先低头、再抬头，两边都够（pitch 要先减掉"正着脸"的基线） ---- */
        if baseHist.count < 60 { baseHist.append(pitch) } else { baseHist.removeFirst(); baseHist.append(pitch) }
        let sorted = baseHist.sorted()
        if !sorted.isEmpty { pitchBase = sorted[sorted.count / 2] }
        let p = pitch - pitchBase
        pitchHist.append((now, p))
        sizeHist.append((now, size))
        while let f = pitchHist.first, now.timeIntervalSince(f.t) > 2.2 { pitchHist.removeFirst() }
        while let f = sizeHist.first, now.timeIntervalSince(f.t) > 2.2 { sizeHist.removeFirst() }
        if pitchHist.count > 200 { pitchHist.removeFirst() }
        if sizeHist.count > 200 { sizeHist.removeFirst() }
        let pDown = pitchHist.filter { $0.v > 0.038 }.count      // 低头
        let pUp = pitchHist.filter { $0.v < -0.038 }.count       // 抬头
        /* 脸的大小要基本没变：**凑近 / 凑远**会让鼻子在画面上"变低"，那也是种"怪动作"，
           但它一定会让人脸框明显变大变小 —— 所以框高起伏超过一成就不算点头。 */
        let sizes = sizeHist.map { $0.v }
        let sMin = sizes.min() ?? 0, sMax = sizes.max() ?? 0
        let steady = sMin > 0.001 && (sMax - sMin) / sMin < 0.12
        if pDown >= 2, pUp >= 2, steady, now.timeIntervalSince(lastNodAt) > 1.0 {
            lastNodAt = now
            pitchHist.removeAll()
            sizeHist.removeAll()
            emit(.nod)
        }
    }
}

extension FaceLiveness: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard running, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let req = VNDetectFaceLandmarksRequest()
        /* 前置摄像头：画面是镜像的，喂给 Vision 也要按 leftMirrored 转 */
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .leftMirrored, options: [:])
        try? handler.perform([req])
        let faces = (req.results ?? []).filter { $0.confidence > 0.4 }
        let now = Date()

        if faces.count > 1 {
            if now.timeIntervalSince(lastMultiAt) > 0.5 {
                lastMultiAt = now
                emit(.multi)
            }
            return
        }

        if let f = faces.first {
            lastFaceAt = now
            /* 环境检测：脸那一块的平均亮度 + 对比度（太暗/太亮/太平都要提示；太平还能当反攻击信号） */
            let q = lightQuality(pb, box: f.boundingBox)
            emit(.face(CGFloat(f.boundingBox.height), q.luma, q.contrast))

            /* 留一帧给后台比对（第一张清晰的就行；过大就压一下） */
            if shot == nil {
                let image = CIImage(cvPixelBuffer: pb)
                if let cg = ci.createCGImage(image, from: image.extent) {
                    let ui = UIImage(cgImage: cg, scale: 1, orientation: .leftMirrored)
                    for q in [CGFloat(0.6), 0.4, 0.25] {
                        if let d = ui.jpegData(compressionQuality: q) {
                            if d.count <= 800_000 || q == 0.25 {
                                shot = "data:image/jpeg;base64," + d.base64EncodedString()
                                break
                            }
                        }
                    }
                }
            }

            /* 眨眼：先攒「睁着眼」的基线，两只眼**一起**闭到 70% 以下、再一起睁回来 → 记一次。
               2026-10-15 修「做怪动作也会过」：以前只取 leftEye ?? rightEye ——
               挤一只眼（wink）、单眼被挡一下都能算「眨眼」；现在两只眼都得真的闭上。 */
            let er = eyeRatios(f)
            if let el = er.left, let rr = er.right {
                if !earClosed {
                    earSamples.append((el + rr) / 2)
                    if earSamples.count > 30 { earSamples.removeFirst() }
                }
                let sorted = earSamples.sorted()
                let base = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
                if base > 0.10 {
                    if !earClosed, el < base * 0.70, rr < base * 0.70 {
                        earClosed = true
                    } else if earClosed, el > base * 0.88, rr > base * 0.88 {
                        earClosed = false
                        if now.timeIntervalSince(lastBlinkAt) > 0.8 {
                            lastBlinkAt = now
                            emit(.blink)
                        }
                    }
                }
            }
            /* 张嘴：连着两帧都张够大才算（单帧抖动不算，咧嘴/皱眉也不至于混过去） */
            if let mo = mouthOpen(f), mo > 0.30 {
                mouthFrames += 1
                if mouthFrames >= 2, now.timeIntervalSince(lastMouthAt) > 1.0 {
                    lastMouthAt = now
                    mouthFrames = 0
                    emit(.mouth)
                }
            } else {
                mouthFrames = 0
            }
            /* 转头 / 点头：按**五官几何**算头姿，再交给时间窗去判「一次真动作」。
               ⚠ 刻意不用 Vision 自带的 yaw/pitch：它和上面这把尺不是同一个量纲，
               两路混着用会出现"一路正、一路负"，凭空凑出左右都甩过的假动作。 */
            if let pg = poseProxy(f) {
                trackPose(yaw: pg.yaw, pitch: pg.pitch, size: Double(f.boundingBox.height), now: now)
            }
        } else if now.timeIntervalSince(lastFaceAt) > 0.5 {
            emit(.noFace)
        }

        if now.timeIntervalSince(lastTick) > 0.5 {
            lastTick = now
            emit(.tick)
        }
    }
}

/// 圆形取景框里的摄像头画面（和扫一扫那套一个做法：UIView + previewLayer）
struct FaceCameraPreview: UIViewRepresentable {
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = FaceLiveness.shared.captureSession
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) { }
}

/* ---------------------------------------------------------- 深度图（防照片 / 屏幕 / AI 图） */

/// 人脸相似度（2026-10-15 用户：「1 2 3 4 优化」的 ②：自动比对）
/// 拿核身那一帧和**账号头像**比一下（Apple 原生的图片特征指纹，不外传）：
/// 给后台一个「像不像同一个人」的参考分——人工比对时先看这个，再自己判断。
enum FaceMatch {
    /// 返回特征距离（越小越像；同一个人一般 < 0.9，不同人 > 1.0）。算不出来返回 nil。
    static func distance(shot dataURL: String, avatar: Data) async -> Double? {
        let head = dataURL.components(separatedBy: "base64,").last ?? ""
        guard !head.isEmpty, let shotData = Data(base64Encoded: head),
              let shot = UIImage(data: shotData), let av = UIImage(data: avatar) else { return nil }
        func print(_ img: UIImage) -> VNFeaturePrintObservation? {
            guard let cg = img.cgImage else { return nil }
            let req = VNGenerateImageFeaturePrintRequest()
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
            return req.results?.first
        }
        guard let a = print(shot), let b = print(av) else { return nil }
        var d: Float = 0
        guard (try? a.computeDistance(&d, to: b)) != nil else { return nil }
        return Double(d)
    }
}

extension FaceLiveness: AVCaptureDepthDataOutputDelegate {
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData,
                         timestamp: CMTime, connection: AVCaptureConnection) {
        guard running else { return }
        /* 只看画面**正中间那块**（脸就在圆框里）：算这块的深度起伏 */
        let conv = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let buf = conv.depthDataMap
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        guard w > 20, h > 20 else { return }
        var lo = Float.greatestFiniteMagnitude, hi: Float = 0
        var n = 0
        var y = h * 3 / 10
        while y < h * 7 / 10 {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: Float.self)
            var x = w * 3 / 10
            while x < w * 7 / 10 {
                let v = row[x]
                if v.isFinite, v > 0 { lo = min(lo, v); hi = max(hi, v); n += 1 }
                x += 4
            }
            y += 4
        }
        guard n > 40, hi > lo else { return }
        depthRangeValue = Double(hi - lo)
    }
}
