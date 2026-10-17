import SwiftUI

/* ============================================================
   长按聊天里的消息 → 微信那一套动作条
   （复制 · 转发 · 收藏 · 引用 · 撤回 · 删除 · 多选 · 举报）
   ============================================================ */

struct MsgAction: Identifiable, Hashable {
    var key: String
    var label: String
    var icon: String
    var danger: Bool = false
    var id: String { key }
}

/* 长按消息弹出来的那个小方框（微信那种：白色圆角框 + 一排图标文字，
   贴在消息旁边，点外面就收起来）。 */
struct MsgMenuBox: View {
    let actions: [MsgAction]
    var onPick: (MsgAction) -> Void

    @Environment(\.colorScheme) private var scheme
    private var bg: Color { scheme == .dark ? Color(hex: 0x3A3A3C) : .white }
    private var ink: Color { scheme == .dark ? Color(hex: 0xEDEDED) : Color(hex: 0x1A1A1A) }

    static let itemW: CGFloat = 56
    static let itemH: CGFloat = 62
    static let padH: CGFloat = 6
    static let padV: CGFloat = 8

    /// 一排最多放几个（微信也是这么横着排）
    static func columns(_ n: Int) -> Int { min(6, max(1, n)) }

    static func size(_ n: Int) -> CGSize {
        let cols = columns(n)
        let rows = Int(ceil(Double(n) / Double(cols)))
        return CGSize(width: CGFloat(cols) * itemW + padH * 2,
                      height: CGFloat(rows) * itemH + padV * 2)
    }

    var body: some View {
        let cols = MsgMenuBox.columns(actions.count)
        let rows = Int(ceil(Double(actions.count) / Double(cols)))
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { idx, a in
                        if idx / cols == r {
                            Button {
                                onPick(a)
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: a.icon)
                                        .font(.system(size: 20))
                                        .foregroundColor(a.danger ? Color(hexString: "#FA5151") : ink)
                                        .frame(height: 22)
                                    Text(Tr(a.label))
                                        .font(pf(11.5))
                                        .foregroundColor(a.danger ? Color(hexString: "#FA5151") : ink)
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                                .frame(width: MsgMenuBox.itemW, height: MsgMenuBox.itemH)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, MsgMenuBox.padH)
        .padding(.vertical, MsgMenuBox.padV)
        /* 和顶栏/底栏/加号卡片同一套玻璃（用户要求弹层统一走玻璃）：
           真玻璃底 + 一层淡淡的白/深色染色（保证图标文字看得清）+ 一道亮边。
           想更透：后台 ui.json 的 menuGlassAlpha（默认 0.92）。 */
        .background {
            ZStack {
                GlassBackground(shape: RoundedRectangle(cornerRadius: 10, style: .continuous),
                                opacity: UIConfig.num("menuGlassAlpha", 0.92),
                                edgeAlpha: UIConfig.num("menuGlassEdge", 0.28),
                                shadow: false,
                                seed: 0.85,
                                native: true)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(bg.opacity(0.55))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.white.opacity(scheme == .dark ? 0.16 : 0.30), lineWidth: 0.6))
        .shadow(color: Color.black.opacity(0.18), radius: 12, y: 4)
    }
}

struct ForwardItem: Hashable {
    var kind: String
    var content: String
}

/* 转发：先选一个聊天（微信也是先选人） */
struct ForwardPickerView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    /// 要转发的内容（可能一次转好几条）
    let items: [ForwardItem]
    var onSent: () -> Void

    @State private var keyword = ""
    @State private var sending = false
    /// 勾了哪几个聊天（微信是「先勾人 → 点发送」，不是一个一个点进去就发）
    @State private var picked: Set<String> = []

    private var list: [Chat] {
        let base = app.chats
        guard !keyword.isEmpty else { return base }
        return base.filter { ($0.name).lowercased().contains(keyword.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("转发给")) {
                Button { dismiss() } label: {
                    Text(Tr("取消")).font(pf(16)).foregroundColor(C.label)
                        .frame(height: L.navH).padding(.trailing, 16)
                }
                .buttonStyle(.plain)
            }

            SearchBoxCenter(text: $keyword).padding(L.searchPad)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(list) { chat in
                        Button {
                            /* 点一下只勾/取消，不直接发（以前点一下就发，而且每行都画着
                               对勾 —— 用户看着就像"默认全勾上了"，还说不出到底发给了谁） */
                            if picked.contains(chat.id) { picked.remove(chat.id) }
                            else { picked.insert(chat.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Avatar(path: chat.avatar ?? "", size: 44, radius: 6)
                                Text(chat.name)
                                    .font(pf(16))
                                    .foregroundColor(C.label)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                /* 没勾 = 空心圈；勾了 = 绿色实心对勾（和微信一样） */
                                Image(systemName: picked.contains(chat.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 19))
                                    .foregroundColor(picked.contains(chat.id) ? C.green : C.searchIcon)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 66)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(C.cardBg)
                        .overlay(alignment: .bottom) { HairLine(inset: 72) }
                    }
                }
            }
            .background(C.pageBg)

            /* 底下那条：显示选了几个 + 发送（一个都没选的时候是灰的） */
            HStack(spacing: 12) {
                Text(picked.isEmpty
                     ? Tr("选择要转发到的聊天")
                     : (Tr("已选") + " " + String(picked.count) + " " + Tr("个聊天")))
                    .font(pf(14))
                    .foregroundColor(C.subLabel)
                Spacer(minLength: 8)
                Button { sendSelected() } label: {
                    Text(sending ? Tr("发送中…") : Tr("发送"))
                        .font(pf(16, .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(picked.isEmpty || sending ? C.subLabel : C.green))
                }
                .buttonStyle(.plain)
                .disabled(picked.isEmpty || sending)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, L.safeBottom + 10)
            .background(C.tabBg)
            .overlay(alignment: .top) { Rectangle().fill(C.navLine).frame(height: 0.5) }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        /* 2026-10-16：「转发给」页补左滑返回 */
        .swipeBack { dismiss() }
    }

    /// 发送：把内容依次发给**勾中的每一个**聊天
    private func sendSelected() {
        let targets = list.filter { picked.contains($0.id) }
        guard !targets.isEmpty else { return }
        sending = true
        Task {
            for chat in targets {
                for it in items {
                    _ = try? await API.shared.send(chatId: chat.id, kind: it.kind, content: it.content)
                }
            }
            sending = false
            if targets.count == 1 {
                app.show(Tr("已转发给") + "「" + targets[0].name + "」")
            } else {
                app.show(Tr("已转发给") + " " + String(targets.count) + " " + Tr("个聊天"))
            }
            onSent()
            dismiss()
        }
    }
}

/* 多选时底下那条：转发 / 收藏 / 删除 */
struct MultiSelectBar: View {
    let count: Int
    var onForward: () -> Void
    var onFavorite: () -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var ink: Color { scheme == .dark ? Color(hex: 0xEDEDED) : Color(hex: 0x1A1A1A) }

    var body: some View {
        HStack(spacing: 0) {
            item("转发", "arrowshape.turn.up.right", onForward)
            item("收藏", "star", onFavorite)
            item("删除", "trash", onDelete, danger: true)
            Button { onCancel() } label: {
                Text(Tr("取消"))
                    .font(pf(15))
                    .foregroundColor(ink)
                    .frame(width: 70, height: 54)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 54)
        .background(C.tabBg)
        .overlay(alignment: .top) { HairLine() }
    }

    private func item(_ title: String, _ icon: String, _ tap: @escaping () -> Void, danger: Bool = false) -> some View {
        Button(action: tap) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18))
                Text(Tr(title)).font(pf(11))
            }
            .foregroundColor(danger ? Color(hexString: "#FA5151") : ink)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
