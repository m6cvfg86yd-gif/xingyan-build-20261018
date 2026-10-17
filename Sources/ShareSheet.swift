import SwiftUI
import UIKit

/* ============================================================
   系统分享面板：把导出的聊天记录丢给「存储到文件 / 隔空投送 / 微信」这些去处。
   用法：.sheet(item: $file) { f in ShareSheet(items: [f.url]) }
   ============================================================ */

/// 一个本地文件（包一层 Identifiable，方便 .sheet(item:)）
struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) { }
}

/// 把一段文本写进临时目录，返回文件地址（导出聊天记录就靠它落成文件）
func writeTempFile(name: String, text: String) -> URL? {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent(name)
    do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    } catch {
        return nil
    }
}
