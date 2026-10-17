import SwiftUI

/// 把每个元素的「真实渲染尺寸」收集起来，回传到电脑上对着参考图校准。
/// 服务器上 data/ui.json 里写 "measure": 1 才开，平时不跑。
@MainActor
final class Measurer: ObservableObject {
    static let shared = Measurer()
    static var enabled: Bool { UIConfig.num("measure", 0) > 0 }

    private var items: [[String: Any]] = []
    private var timer: Task<Void, Never>?

    func add(_ key: String, _ frame: CGRect) {
        guard Measurer.enabled else { return }
        items.append([
            "key": key,
            "x": (frame.minX * 10).rounded() / 10,
            "y": (frame.minY * 10).rounded() / 10,
            "w": (frame.size.width * 10).rounded() / 10,
            "h": (frame.size.height * 10).rounded() / 10
        ])
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self = self, !Task.isCancelled else { return }
            let payload = self.items
            self.items = []
            await API.shared.reportMeasure(payload)
        }
    }
}

struct MeasureModifier: ViewModifier {
    let key: String
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear.onAppear {
                    let f = geo.frame(in: .global)
                    Task { @MainActor in Measurer.shared.add(key, f) }
                }
            }
        )
    }
}

extension View {
    func measure(_ key: String) -> some View { modifier(MeasureModifier(key: key)) }
}
