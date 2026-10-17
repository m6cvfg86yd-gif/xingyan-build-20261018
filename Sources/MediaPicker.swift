import SwiftUI
import UIKit
import PhotosUI
import Photos
import UniformTypeIdentifiers
import AVFoundation

/// 一次多选时，把逐张加载回来的图片收好；「交付」只允许发生一次。
/// （写完整个数组再一次性交出去，避免中途交付半张。）
final class MultiPick {
    private let lock = NSLock()
    private var imgs: [UIImage?]
    private var done = false

    init(count: Int) { imgs = [UIImage?](repeating: nil, count: count) }

    func put(_ img: UIImage?, at i: Int) {
        lock.lock()
        if i >= 0, i < imgs.count { imgs[i] = img }
        lock.unlock()
    }

    /// 第一次调用返回图片数组，之后返回 nil（保证只交付一次）
    func take() -> [UIImage]? {
        lock.lock(); defer { lock.unlock() }
        if done { return nil }
        done = true
        return imgs.compactMap { $0 }
    }
}

/* ============================================================
   聊天里的「照片」入口 —— 支持三种：
     · 普通照片  → onImage
     · 视频      → onVideo（给一个临时文件 URL，调用方负责上传）
     · 实况照片  → onLive（实况 = 一张图 + 一小段视频，两个都给）
   为什么要单独写一个：老的 PhotoPicker 写死了 filter = .images、只 loadObject(UIImage)，
   选视频/实况时那个判断直接 false，什么都不发生（用户看到的就是「发不了」）。
   ============================================================ */

struct MediaPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    var onVideo: (URL) -> Void
    var onLive: (UIImage, URL) -> Void
    /// 只挑视频（朋友圈发视频用）
    var videosOnly: Bool = false
    /// 一次最多能挑几张（1 = 单选，还是老样子）
    var maxImages: Int = 1
    /// 一次挑了好几张普通照片：一起回调（调用方拿去发一条「九宫格」消息）
    var onImages: (([UIImage]) -> Void)? = nil
    /// 想说一句话给用户听（比如"实况一次只能发一张"）
    var onNotice: ((String) -> Void)? = nil

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = videosOnly ? .videos : .any(of: [.images, .videos, .livePhotos])
        cfg.selectionLimit = videosOnly ? 1 : max(1, maxImages)
        cfg.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) { }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: MediaPicker
        init(_ p: MediaPicker) { parent = p }

        /* 实况照片在 PHPicker 里给的类型：**不是 public.movie**。
             · com.apple.live-photo-bundle —— iOS 15+ 给的是这个「包」（里面是一张图 + 一段 MOV）
             · com.apple.live-photo        —— UTType.livePhoto（老一点的系统）
           以前这里只判断 UTType.movie，实况永远判不出来，就被当成普通静态图发出去
           （用户反馈的「照片无法发实况」就是这么来的）。 */
        private static let liveBundleType = "com.apple.live-photo-bundle"

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            /* 一次挑了好几张：都当成普通照片收下来，一次性交给调用方
               （视频/实况混在里面时，只收能当图片读的那几张；只有一张还是走老逻辑） */
            if results.count > 1 {
                let group = DispatchGroup()
                let box = MultiPick(count: results.count)
                CrashCatcher.note("选图", "一次选了 \(results.count) 张")

                /* 多选里如果混着实况照片，得跟用户说清楚：
                   多选那条路只能当图片发，**没有「实况」开关**（用户反馈的"没有实况的选择"）。
                   微信也是实况一次只能发一张。 */
                let liveCount = results.filter {
                    $0.itemProvider.hasItemConformingToTypeIdentifier(Self.liveBundleType)
                        || $0.itemProvider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier)
                }.count
                if liveCount > 0 {
                    CrashCatcher.note("选图", "多选里含 \(liveCount) 张实况（多选只能当静图发）")
                    DispatchQueue.main.async {
                        self.parent.onNotice?(liveCount == results.count
                            ? "实况照片一次只能发一张：想发动效就单张选，多选会按静态图发"
                            : "里面有 \(liveCount) 张实况：多选会按静态图发，想发动效请单张选")
                    }
                }

                for (i, r) in results.enumerated() {
                    let p = r.itemProvider
                    guard p.canLoadObject(ofClass: UIImage.self) else { continue }
                    group.enter()
                    loadImage(p) { img in
                        box.put(img, at: i)
                        group.leave()
                    }
                }
                /* 交付：可能被调两次（正常回调 + 下面的兜底），所以只能交一次 */
                let deliver = {
                    guard let list = box.take() else { return }
                    CrashCatcher.note("选图", "拿到 \(list.count) 张，交给发送")
                    guard !list.isEmpty else { return }
                    if list.count > 1, let multi = self.parent.onImages {
                        multi(list)
                    } else if let one = list.first {
                        self.parent.onImage(one)
                    }
                }
                group.notify(queue: .main, execute: deliver)
                /* 兜底：iCloud 里的大图/视频可能半天给不出来，
                   以前这种情况**什么都没发生**（用户只能一张一张再发一遍）。
                    2.5 秒还没全回来就先用已经拿到的发出去。 */
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: deliver)
                return
            }
            guard let provider = results.first?.itemProvider else { return }
            let hasMovie = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            let hasImage = provider.canLoadObject(ofClass: UIImage.self) ||
                provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)

            /* 这一张是不是实况照片 */
            let isLive = provider.hasItemConformingToTypeIdentifier(Self.liveBundleType)
                || provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier)
                /* 再加一条宽松匹配：有些系统版本给的类型名带 live 但不是上面这两个
                   （比如各种 com.apple.live-photo* 的变体），按关键字兜住 */
                || provider.registeredTypeIdentifiers.contains { $0.lowercased().contains("live") }

            /* 诊断上报：用户反馈"发不了实况"时，看后台日志就知道卡在哪一步 ——
               是这个系统给的又不是 live-photo-bundle、还是动效那段没取到（退回静图了）。 */
            CrashCatcher.note("选图",
                "types=[\(provider.registeredTypeIdentifiers.joined(separator: ","))]"
                + " live=\(isLive) movie=\(hasMovie) image=\(hasImage)"
                + " hasBundle=\(provider.hasItemConformingToTypeIdentifier(Self.liveBundleType))"
                + " hasLiveType=\(provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier))")

            /* 实况：图 + 那段动效都要 —— 两个都取（拿不到动效就退回普通图片，别什么都不发） */
            if isLive || (hasMovie && hasImage) {
                loadImage(provider) { img in
                    guard let img = img else {
                        CrashCatcher.note("实况", "静态图没取到，放弃")
                        return
                    }
                    self.loadLiveMovie(provider) { url in
                        if let url = url {
                            CrashCatcher.note("实况", "动效取到了：\(url.lastPathComponent)")
                            DispatchQueue.main.async { self.parent.onLive(img, url) }
                            return
                        }
                        /* PHPicker 这条路没拿到动效：用选中的那个相册资源再试一次
                           —— 相片在 iCloud 里没下载到本机时，PHPicker 经常给不出视频，
                           走 PHAssetResource 能把 iCloud 那份也拉下来。 */
                        CrashCatcher.note("实况", "PHPicker 没给动效 → 试 PHAsset 兜底")
                        self.loadLiveViaAsset(results.first?.assetIdentifier) { url2 in
                            if let url2 = url2 {
                                DispatchQueue.main.async { self.parent.onLive(img, url2) }
                            } else {
                                CrashCatcher.note("实况", "兜底也没拿到 → 退回发静态图")
                                DispatchQueue.main.async { self.parent.onImage(img) }
                            }
                        }
                    }
                }
                return
            }
            /* 视频 */
            if hasMovie {
                loadMovie(provider) { url in
                    guard let url = url else { return }
                    DispatchQueue.main.async { self.parent.onVideo(url) }
                }
                return
            }
            /* 普通照片 */
            loadImage(provider) { img in
                guard let img = img else { return }
                DispatchQueue.main.async { self.parent.onImage(img) }
            }
        }

        private func loadImage(_ p: NSItemProvider, _ done: @escaping (UIImage?) -> Void) {
            if p.canLoadObject(ofClass: UIImage.self) {
                p.loadObject(ofClass: UIImage.self) { obj, _ in done(obj as? UIImage) }
                return
            }
            p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                done(data.flatMap { UIImage(data: $0) })
            }
        }

        /// 取视频文件：系统给的是临时文件，必须在回调里马上拷出来（出了回调就没了）
        private func loadMovie(_ p: NSItemProvider, _ done: @escaping (URL?) -> Void) {
            p.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url = url else { done(nil); return }
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("chris-video-\(UUID().uuidString).mov")
                do {
                    try? FileManager.default.removeItem(at: dst)
                    try FileManager.default.copyItem(at: url, to: dst)
                    done(dst)
                } catch { done(nil) }
            }
        }

        /// 取实况那段动效：能直接给 movie 的走 movie；给的是 live-photo-bundle（一个包目录）
        /// 就进去把里面的 .MOV 拷出来
        private func loadLiveMovie(_ p: NSItemProvider, _ done: @escaping (URL?) -> Void) {
            if p.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                loadMovie(p) { url in
                    if let url = url { done(url) } else { self.loadLiveBundle(p, done) }
                }
                return
            }
            loadLiveBundle(p, done)
        }

        private func loadLiveBundle(_ p: NSItemProvider, _ done: @escaping (URL?) -> Void) {
            let type: String
            if p.hasItemConformingToTypeIdentifier(Self.liveBundleType) {
                type = Self.liveBundleType
            } else if p.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier) {
                type = UTType.livePhoto.identifier
            } else {
                done(nil); return
            }
            p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url = url else {
                    CrashCatcher.note("实况", "loadFileRepresentation 没给 url（type=\(type)）")
                    done(nil); return
                }
                /* 这个「包」是一个目录：里面有一张封面图 + 一段 MOV；
                   也有系统直接给单个 .mov 的情况，两种都认。 */
                var src: URL? = nil
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    let items = (try? FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: nil)) ?? []
                    src = items.first { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
                } else if ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) {
                    src = url
                }
                guard let from = src else {
                    CrashCatcher.note("实况", "包里没找到视频：\(url.lastPathComponent)")
                    done(nil); return
                }
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("chris-live-\(UUID().uuidString).mov")
                do {
                    try? FileManager.default.removeItem(at: dst)
                    try FileManager.default.copyItem(at: from, to: dst)
                    done(dst)
                } catch { done(nil) }
            }
        }

        /// 最后一道兜底：用相册资源（PHAssetResource）把实况那段视频拉出来。
        /// isNetworkAccessAllowed = true 表示相片只在 iCloud 上也能下 —— 这是
        /// "开了 iCloud 照片优化存储"的人发不出实况最常见的原因。
        private func loadLiveViaAsset(_ assetId: String?, _ done: @escaping (URL?) -> Void) {
            guard let assetId = assetId, !assetId.isEmpty else { done(nil); return }
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else {
                /* 没授权就别弹窗打扰（PHPicker 本身不需要权限），直接放弃 */
                CrashCatcher.note("实况", "相册未授权，PHAsset 兜底跳过（status=\(status.rawValue)）")
                done(nil); return
            }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
                CrashCatcher.note("实况", "PHAsset 按 id 找不到资源")
                done(nil); return
            }
            let resources = PHAssetResource.assetResources(for: asset)
            guard let video = resources.first(where: { $0.type == .fullSizeVideo || $0.type == .video }) else {
                CrashCatcher.note("实况", "PHAsset 里没有视频资源（只有 \(resources.count) 个资源）")
                done(nil); return
            }
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("chris-live-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: dst)
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: video, toFile: dst, options: opts) { err in
                if err == nil, FileManager.default.fileExists(atPath: dst.path) {
                    CrashCatcher.note("实况", "PHAsset 兜底成功（type=\(video.type.rawValue)）")
                    done(dst)
                } else {
                    CrashCatcher.note("实况", "PHAsset 兜底失败：\(err?.localizedDescription ?? "未知错误")")
                    done(nil)
                }
            }
        }
    }
}

/* ============================================================
   朋友圈的相册入口（微信那个 ＋ / 「从相册选择」）：
   · 照片一次可以挑多张（最多 9 张，顺序就是选图顺序）
   · 挑到视频就按「一条视频」发（微信也是：视频和照片不混着发）
   · 实况照片按静态图算（朋友圈暂时按图片发）
   ============================================================ */

enum MomentPickResult {
    case images([UIImage])
    case video(URL)
}

struct MomentPicker: UIViewControllerRepresentable {
    /// 最多几张（微信 9 张）
    var limit: Int = 9
    var onResult: (MomentPickResult) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = .any(of: [.images, .videos])       // 关键：照片和视频都能选
        cfg.selectionLimit = max(1, limit)
        cfg.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) { }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: MomentPicker
        init(_ p: MomentPicker) { parent = p }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }
            /* 挑到视频（实况不算，实况按照片发）→ 按一条视频走 */
            let movie = results.first { r in
                let p = r.itemProvider
                return p.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                    && !p.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier)
            }
            if let mv = movie {
                loadMovie(mv.itemProvider) { url in
                    guard let url = url else { return }
                    DispatchQueue.main.async { self.parent.onResult(.video(url)) }
                }
                return
            }
            loadImages(results) { imgs in
                guard !imgs.isEmpty else { return }
                DispatchQueue.main.async { self.parent.onResult(.images(imgs)) }
            }
        }

        private func loadImage(_ p: NSItemProvider, _ done: @escaping (UIImage?) -> Void) {
            if p.canLoadObject(ofClass: UIImage.self) {
                p.loadObject(ofClass: UIImage.self) { obj, _ in done(obj as? UIImage) }
                return
            }
            p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                done(data.flatMap { UIImage(data: $0) })
            }
        }

        /// 一次挑多张：全部取完一次性回调（顺序保持选择顺序）
        private func loadImages(_ results: [PHPickerResult], _ done: @escaping ([UIImage]) -> Void) {
            var out = [UIImage?](repeating: nil, count: results.count)
            let group = DispatchGroup()
            for (i, r) in results.enumerated() {
                group.enter()
                loadImage(r.itemProvider) { img in
                    out[i] = img
                    group.leave()
                }
            }
            group.notify(queue: .main) { done(out.compactMap { $0 }) }
        }

        private func loadMovie(_ p: NSItemProvider, _ done: @escaping (URL?) -> Void) {
            p.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url = url else { done(nil); return }
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("chris-moment-\(UUID().uuidString).mov")
                do {
                    try? FileManager.default.removeItem(at: dst)
                    try FileManager.default.copyItem(at: url, to: dst)
                    done(dst)
                } catch { done(nil) }
            }
        }
    }
}

/* ---------------------------------------------------------- 视频工具 */

enum MediaTool {
    /// 上传一个本地文件（走 /api/upload/raw 那条二进制通道，比 base64 省内存）
    static func upload(_ url: URL) async -> String? {
        let ext = url.pathExtension.lowercased()
        let mime = (ext == "mov") ? "video/quicktime" : "video/mp4"
        /* 直接读文件会先把整段视频塞进内存（几十 MB 就很容易被系统杀掉），
           走 URLSession 的文件流上传 + 进度回调，内存友好还能出进度条。 */
        return try? await API.shared.uploadBinaryFile(url, mime: mime) { _ in }
    }

    /// 带进度的上传（视频发送时那个转圈进度条）。
    /// skipServerTranscode：这条已经在手机上压好了，让服务器别再压第二遍。
    static func upload(_ url: URL, onProgress: @escaping (Double) -> Void,
                       skipServerTranscode: Bool = false) async -> String? {
        let ext = url.pathExtension.lowercased()
        let mime = (ext == "mov") ? "video/quicktime" : "video/mp4"
        return try? await API.shared.uploadBinaryFile(url, mime: mime,
                                                     skipTranscode: skipServerTranscode,
                                                     onProgress: onProgress)
    }

    /// 视频时长（秒）
    static func seconds(_ url: URL) async -> Int {
        let asset = AVURLAsset(url: url)
        let d = (try? await asset.load(.duration))?.seconds ?? 0
        return max(1, Int(d.rounded()))
    }

    /// 视频的显示宽高（像素）。注意要带上 preferredTransform ——
    /// 手机竖着拍的视频 naturalSize 是 1920x1080 + 一个 90° 旋转，
    /// 不对它做变换就会把竖屏视频当成横屏，气泡尺寸正好反过来。
    static func aspect(_ url: URL) async -> (w: Int, h: Int)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let sz = try? await track.load(.naturalSize),
              let tx = try? await track.load(.preferredTransform) else { return nil }
        let t = sz.applying(tx)
        let w = Int(abs(t.width).rounded())
        let h = Int(abs(t.height).rounded())
        guard w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// 取第一帧当封面（返回图片本身；调用方把它上传掉，拿服务器路径写进消息里）
    static func firstFrame(_ url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 1280)
        guard let cg = try? await gen.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 这个视频还需不需要压？
    /// 重编码是把整段视频一秒一秒重新算一遍，几十秒的视频要等十几秒 —— 用户感觉就是"发视频很慢"。
    /// 已经够小够清楚的（≤8MB、≤60 秒、长边 ≤1280）就直接发，不压；微信也是这么干的。
    static func needsCompress(_ url: URL) async -> Bool {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        let asset = AVURLAsset(url: url)
        let secs = (try? await asset.load(.duration))?.seconds ?? 0
        var longSide = 0
        if let tracks = try? await asset.loadTracks(withMediaType: .video),
           let track = tracks.first,
           let sz = try? await track.load(.naturalSize) {
            longSide = Int(max(abs(sz.width), abs(sz.height)))
        }
        /* 2026-10-14 复盘（实测）：这条路只有约 **0.3MB/s**。
           所以"直接传大文件"并不快 —— 30MB 要 100 秒；而先压成 720p（约 5MB）再传，
           只要"压缩 20 秒 + 上传 17 秒"。**门槛放回原来的 8MB**：
           小视频（≤8MB/≤60秒/≤1280）直接秒传；大视频先压小再传（总时间反而更短）。
           （中途试过一次放宽到 40MB，结果是"大视频在慢慢传进度条"，已纠正。） */
        if size > 0, size <= 8 * 1024 * 1024, secs > 0, secs <= 60, longSide > 0, longSide <= 1280 {
            return false
        }
        return true
    }

    /// 压缩视频（微信默认就会压）：720p，压完再发；「原图」开关打开就跳过这一步。
    /// onProgress：0…1。AVAssetExportSession 自己不通知进度，只能轮询它的 progress。
    static func compress(_ url: URL, onProgress: ((Double) -> Void)? = nil) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("chris-send-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        /* 进度：AVAssetExportSession 的 progress 在有的机型/有的视频上会一直停在 0，
           用户看到的就是「进度条一直不动」。所以再叠一层**时间估算**兜底：
           压缩耗时大约跟视频时长成正比，按 0.5 倍时长估，取两者较大的那个，
           真压完再跳到 1。这样进度条始终在动。 */
        let t0 = Date()
        let secs = (try? await asset.load(.duration))?.seconds ?? 10
        let guessSpan = max(1.5, min(60, secs * 0.5))
        let poll = Task {
            while !Task.isCancelled {
                let real = Double(export.progress)
                let elapsed = Date().timeIntervalSince(t0)
                let guess = min(0.95, elapsed / guessSpan)
                onProgress?(max(real, guess))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        poll.cancel()
        onProgress?(1)
        return export.status == .completed ? out : nil
    }
}

/* ============================================================
   选完之后的发送预览页（和微信一致）：
     · 左边预览，底部两个开关：「原图」和「实况」（实况只在实况照片时出现）
     · 点「发送」才真发出去；不点就取消，不会误发
   ============================================================ */

struct MediaSendSheet: View {
    enum Payload {
        case image(UIImage)
        /// 一次选了好几张：发成一条「九宫格」消息
        case images([UIImage])
        case video(URL, UIImage?)          // 视频文件 + 预览图
        case live(UIImage, URL)            // 实况：静态图 + 那一小段动效
    }

    let payload: Payload
    /// (要不要按实况发, 要不要发原图)
    var onSend: (Bool, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 实况开关：**默认打开** —— 从相册选了一张实况照片，就直接按实况发出去
    /// （用户要求"直接在相册里可以发实况"；微信默认是关的，但我们不做那一步多余的开关动作）
    @State private var liveOn = true
    @State private var originalOn = false    // 默认压缩

    private var isLive: Bool { if case .live = payload { return true }; return false }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                preview
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 12) {
                if isLive {
                    toggleRow(Tr("实况"), sub: Tr("打开后对方长按可以看这段动效（两边都是 iPhone 才有效）"), on: $liveOn)
                }
                toggleRow(Tr("原图"), sub: Tr("不压缩，画质最好但发得慢、对方加载慢"), on: $originalOn)

                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Text(Tr("取消"))
                            .font(.system(size: 16))
                            .foregroundColor(C.label)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.dyn(0xEFEFF1, 0x2C2C2E)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        onSend(liveOn, originalOn)
                        dismiss()
                    } label: {
                        Text(Tr("发送"))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(C.green))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .background(Color.dyn(0xFFFFFF, 0x1C1C1E))
        }
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var preview: some View {
        switch payload {
        case .image(let img):
            Image(uiImage: img).resizable().scaledToFit()
        case .images(let list):
            /* 多选：预览页里先摆成九宫格，能看出这一条要发几张 */
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3),
                          spacing: 3) {
                    ForEach(Array(list.enumerated()), id: \.offset) { _, img in
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 112)
                            .clipped()
                    }
                }
                .padding(10)
            }
        case .video(_, let cover):
            if let c = cover {
                Image(uiImage: c).resizable().scaledToFit()
                    .overlay(Image(systemName: "play.circle.fill").font(.system(size: 46)).foregroundColor(.white.opacity(0.9)))
            } else {
                Image(systemName: "video.fill").font(.system(size: 54)).foregroundColor(.white.opacity(0.8))
            }
        case .live(let img, _):
            Image(uiImage: img).resizable().scaledToFit()
                .overlay(alignment: .topLeading) {
                    Text(Tr("实况")).font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                        .padding(12)
                }
        }
    }

    private func toggleRow(_ title: String, sub: String, on: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15)).foregroundColor(C.label)
                Text(sub).font(.system(size: 12)).foregroundColor(C.subLabel)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: on).labelsHidden()
        }
    }
}
