import SwiftUI
import UIKit

/// 让 UIKit 输入框沿用 App 自己的苹方、后台字号倍率和关怀模式。
func chatComposerUIFont(_ size: CGFloat = 17) -> UIFont {
    let scaled = max(9, (size * fontScale * CareMode.scale).rounded())
    if let name = pfName(.regular), let font = UIFont(name: name, size: scaled) {
        return font
    }
    return .systemFont(ofSize: scaled)
}

/// 聊天输入框的 UIKit 桥。
///
/// SwiftUI 的 TextField 不暴露当前选区；表情面板一点开又会收起键盘，
/// 于是表情只能追加到末尾。这里用 UITextField 自己记住最后一次选区，
/// 表情和小键盘退格都直接作用在光标位置。
@MainActor
final class ChatComposerBridge: ObservableObject {
    fileprivate weak var textField: UITextField?
    private var lastSelection = NSRange(location: 0, length: 0)

    fileprivate func attach(_ field: UITextField) {
        textField = field
        rememberSelection(in: field)
    }

    fileprivate func rememberSelection(in field: UITextField) {
        guard let range = field.selectedTextRange else { return }
        let start = field.offset(from: field.beginningOfDocument, to: range.start)
        let end = field.offset(from: field.beginningOfDocument, to: range.end)
        lastSelection = NSRange(location: start, length: max(0, end - start))
    }

    func insert(_ text: String) {
        replaceSelection(with: text)
    }

    func deleteBackward() {
        guard let field = textField else { return }
        let current = field.text ?? ""
        let selected = currentSelection(in: field, textCount: (current as NSString).length)

        if selected.length > 0 {
            replaceSelection(with: "")
            return
        }

        guard selected.location > 0,
              let cursor = Range(NSRange(location: selected.location, length: 0), in: current),
              let from = current.index(cursor.lowerBound, offsetBy: -1, limitedBy: current.startIndex)
        else { return }

        let range = from..<cursor.lowerBound
        let cursorUTF16 = current.utf16.distance(from: current.startIndex, to: from)
        let next = current.replacingCharacters(in: range, with: "")
        apply(next, cursorUTF16: cursorUTF16)
    }

    private func replaceSelection(with text: String) {
        guard let field = textField else { return }
        let current = field.text ?? ""
        let selected = currentSelection(in: field, textCount: (current as NSString).length)
        guard let range = Range(selected, in: current) else { return }

        let insertion = text as NSString
        let next = current.replacingCharacters(in: range, with: text)
        let cursor = selected.location + insertion.length
        apply(next, cursorUTF16: cursor)
    }

    private func currentSelection(in field: UITextField, textCount: Int) -> NSRange {
        rememberSelection(in: field)
        let upper = max(0, textCount)
        let location = min(max(0, lastSelection.location), upper)
        let length = min(max(0, lastSelection.length), upper - location)
        return NSRange(location: location, length: length)
    }

    private func apply(_ text: String, cursorUTF16: Int) {
        guard let field = textField else { return }
        field.text = text
        field.sendActions(for: .editingChanged)

        let upper = (text as NSString).length
        let safe = min(max(0, cursorUTF16), upper)
        if let cursor = field.position(from: field.beginningOfDocument, offset: safe) {
            field.selectedTextRange = field.textRange(from: cursor, to: cursor)
        }
        lastSelection = NSRange(location: safe, length: 0)
    }
}

/// 和原 SwiftUI TextField 外观一致的聊天输入框，额外保留选区给表情面板使用。
struct ChatComposerTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let bridge: ChatComposerBridge
    let font: UIFont
    let tintColor: UIColor
    let onBeginEditing: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.clearButtonMode = .never
        field.font = font
        field.tintColor = tintColor
        field.textColor = .label
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator,
                        action: #selector(Coordinator.textChanged(_:)),
                        for: .editingChanged)
        bridge.attach(field)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        bridge.attach(field)
        field.font = font
        field.tintColor = tintColor

        if field.text != text {
            let old = field.selectedTextRange
            field.text = text
            if let old = old,
               let start = field.position(from: field.beginningOfDocument,
                                          offset: field.offset(from: field.beginningOfDocument, to: old.start)),
               let end = field.position(from: field.beginningOfDocument,
                                        offset: field.offset(from: field.beginningOfDocument, to: old.end)) {
                field.selectedTextRange = field.textRange(from: start, to: end)
            }
            bridge.rememberSelection(in: field)
        }

        if focused && !field.isFirstResponder {
            DispatchQueue.main.async {
                guard self.focused, !field.isFirstResponder else { return }
                field.becomeFirstResponder()
            }
        } else if !focused && field.isFirstResponder {
            DispatchQueue.main.async {
                guard !self.focused, field.isFirstResponder else { return }
                field.resignFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ChatComposerTextField

        init(parent: ChatComposerTextField) {
            self.parent = parent
        }

        @objc func textChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
            parent.bridge.rememberSelection(in: field)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.focused = true
            parent.bridge.rememberSelection(in: textField)
            parent.onBeginEditing()
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.focused = false
        }

        func textFieldDidChangeSelection(_ textField: UITextField) {
            parent.bridge.rememberSelection(in: textField)
        }
    }
}
