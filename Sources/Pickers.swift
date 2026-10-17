import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

/// 系统相册（PHPicker，不给权限也能用，选完直接回调）
struct PhotoPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .images
        cfg.selectionLimit = 1
        cfg.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (UIImage) -> Void
        init(onPick: @escaping (UIImage) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async { self.onPick(image) }
            }
        }
    }
}

/// 拍照
/* ============================================================
   相册选一张图（不依赖 SwiftUI 的 sheet）
   扫一扫是全屏相机页，从里面再弹 SwiftUI 的 sheet 有时候弹不出来；
   而且 PHPicker 自己 dismiss 之后 SwiftUI 还以为在展示，第二次点就没反应了。
   这里直接找到最上面的控制器把它 present 出来，最稳。
   ============================================================ */
enum AlbumPicker {
    private static var keep: AlbumDelegate?

    static func present(_ onPick: @escaping (UIImage) -> Void) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController else { return }
        var cfg = PHPickerConfiguration()
        cfg.filter = .images
        cfg.selectionLimit = 1
        cfg.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: cfg)
        let d = AlbumDelegate(onPick: onPick)
        vc.delegate = d
        keep = d                       // 保住 delegate，不然会被放了
        var top = root
        while let p = top.presentedViewController { top = p }
        top.present(vc, animated: true)
    }

    final class AlbumDelegate: NSObject, PHPickerViewControllerDelegate {
        private let onPick: (UIImage) -> Void
        init(onPick: @escaping (UIImage) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else {
                AlbumPicker.keep = nil
                return
            }
            let finish: (UIImage?) -> Void = { img in
                DispatchQueue.main.async {
                    if let img = img { self.onPick(img) }
                    AlbumPicker.keep = nil
                }
            }
            /* **先拿原始数据降采样**：以前是 loadObject(UIImage) 把整张原图解出来，
               连着换两张图（头像 → 封面）内存就能冲到被系统杀掉（用户报的
               「换了一个新闻头像就崩了」）。降采样失败再退回老路。 */
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                if let d = data, let img = RemoteImage.downsampled(d, maxSide: 2048) { finish(img); return }
                if provider.canLoadObject(ofClass: UIImage.self) {
                    provider.loadObject(ofClass: UIImage.self) { object, _ in
                        finish((object as? UIImage) ?? data.flatMap { UIImage(data: $0) })
                    }
                } else {
                    finish(data.flatMap { UIImage(data: $0) })
                }
            }
        }
    }
}

/// 相册多选（最多 limit 张，回调按用户选择的先后顺序给回来）
struct PhotosPicker: UIViewControllerRepresentable {
    var limit: Int = 9
    var onPick: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .images
        cfg.selectionLimit = limit
        cfg.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([UIImage]) -> Void
        init(onPick: @escaping ([UIImage]) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }
            let group = DispatchGroup()
            var images = [UIImage?](repeating: nil, count: results.count)
            results.enumerated().forEach { idx, r in
                guard r.itemProvider.canLoadObject(ofClass: UIImage.self) else { return }
                group.enter()
                r.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                    images[idx] = obj as? UIImage          // 按下标放回：顺序就是用户点的顺序
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let list = images.compactMap { $0 }
                if !list.isEmpty { self.onPick(list) }
            }
        }
    }
}

/// 拍照
struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    /// 给了这个回调，相机就**同时带照片和视频两种模式**
    /// （系统相机底部会出现「照片 / 视频」切换条，和微信那个拍摄页一样）——
    /// 这样"按住拍视频"万一没生效，用户也能自己在相机里切到视频录。
    var onVideo: ((URL) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        if onVideo != nil {
            vc.mediaTypes = ["public.image", "public.movie"]
            vc.videoQuality = .typeHigh
            vc.videoMaximumDuration = 60
        }
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onVideo: onVideo) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage) -> Void
        let onVideo: ((URL) -> Void)?
        init(onPick: @escaping (UIImage) -> Void, onVideo: ((URL) -> Void)?) {
            self.onPick = onPick
            self.onVideo = onVideo
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            /* 录了视频 → 走视频那条路；拍了照片 → 走照片那条路 */
            if let url = info[.mediaURL] as? URL, let cb = onVideo {
                cb(url)
                return
            }
            if let image = info[.originalImage] as? UIImage { onPick(image) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

/* ============================================================
   拍视频：「拍照」那个按钮**长按**进来的。
   和 CameraPicker 同一套系统相机，只是直接进录像模式（微信里长按拍照就是拍小视频），
   录完把临时文件 URL 交回去 —— 调用方负责传服务器（和「从相册选视频」同一条路）。
   ============================================================ */
struct CameraVideoPicker: UIViewControllerRepresentable {
    /// 录完的视频临时文件（拍照兜底成相册时，选中的视频也会走这里）
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        let hasCamera = UIImagePickerController.isSourceTypeAvailable(.camera)
        vc.sourceType = hasCamera ? .camera : .photoLibrary
        /* 只出视频：相机界面直接就是录像；相册兜底时也只列视频 */
        vc.mediaTypes = ["public.movie"]
        vc.videoQuality = .typeHigh
        vc.videoMaximumDuration = 60        // 和微信一样，最长 60 秒
        /* cameraCaptureMode 只在摄像头这一路有效，设到相册那路会抛异常 */
        if hasCamera { vc.cameraCaptureMode = .video }
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            /* 老系统的 .mediaURL 就是临时文件；新版也可能回 .mediaURL，两条都试一下 */
            if let url = (info[.mediaURL] as? URL) {
                onPick(url)
            } else if let url = (info[.referenceURL] as? URL) {
                onPick(url)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
