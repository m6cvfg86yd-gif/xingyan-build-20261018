import SwiftUI

/* ============================================================
   「高级版」面板零件

   群聊信息面板 / 单聊信息面板 / 名片右上「⋯」这三处共用这一套：
     · 分区小标题（「群成员」「设置」「记录」…）
     · 圆角 14 的卡片：底色 + 一圈极细描边 + 很轻的投影
     · 行首一枚 30×30 的渐变圆角图标底（白色图标），行高 56
   配色沿用「个人信息」页那套绿/蓝/紫/橙，三处看起来是一家的。
   功能逻辑一个字没动，只换了外观。
   ============================================================ */

/// 卡片之间的小标题
struct PanelSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(pf(12.5, .medium))
            .foregroundColor(C.subLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }
}

/// 圆角 14 的卡片
struct PanelCard<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { CardGlassBox(radius: 14) }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(C.hairline, lineWidth: 0.6))
            .shadow(color: Color.black.opacity(0.05), radius: 8, y: 2)
    }
}

/// 深色「英雄卡」：群聊 / 单聊信息面板顶上那一张（渐变底 + 右上角一圈柔光）
struct PanelHeroCard<Content: View>: View {
    private let glow: Color
    private let content: () -> Content

    init(glow: Color = C.green, @ViewBuilder content: @escaping () -> Content) {
        self.glow = glow
        self.content = content
    }

    var body: some View {
        VStack(spacing: 14) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                ZStack {
                    LinearGradient(colors: [Color(hex: 0x1C2130), Color(hex: 0x2A2433), Color(hex: 0x14111A)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    RadialGradient(colors: [glow.opacity(0.26), Color.clear],
                                   center: .topTrailing, startRadius: 2, endRadius: 210)
                    /* 2026-10-16「个人名片渲染一下感觉」：左上角再补一层很淡的白色高光 ——
                       深色渐变有了高光就像玻璃/金属，不再是纯色块 */
                    RadialGradient(colors: [Color.white.opacity(0.10), Color.clear],
                                   center: .topLeading, startRadius: 1, endRadius: 260)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 1))
            .overlay(
                /* 顶上那一道更亮的内边：卡片的"厚度"就是靠它 */
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.22), Color.clear],
                                           startPoint: .top, endPoint: .center),
                            lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.26), radius: 18, y: 9)
            .shadow(color: (glow).opacity(0.12), radius: 16, y: 4)
    }
}

/// 英雄卡里那个小胶囊（群二维码 / 查找记录 / 语音通话…）
struct PanelPill: View {
    var symbol: String
    var title: String
    var colors: [Color] = PanelTint.green
    var tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(pf(13, .medium))
                    .lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                Capsule().fill(LinearGradient(colors: colors.map { $0.opacity(0.9) },
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }
}

/// 行首的小图标底：圆角渐变方块 + 白色图标
struct PanelIcon: View {
    var symbol: String
    var colors: [Color] = PanelTint.green
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
            Image(systemName: symbol)
                .font(.system(size: size * 0.47, weight: .semibold))
                .foregroundColor(.white)
        }
        .shadow(color: (colors.last ?? .clear).opacity(0.32), radius: 4, y: 2)
    }
}

/// 配色：和信息页那套保持一致
enum PanelTint {
    static let green: [Color] = [C.green, C.green.opacity(0.78)]
    static let blue: [Color] = [Color(hex: 0x64B5F6), Color(hex: 0x2A6BC4)]
    static let purple: [Color] = [Color(hex: 0xB98CFF), Color(hex: 0x7A45D6)]
    static let orange: [Color] = [Color(hex: 0xFFB627), Color(hex: 0xF08600)]
    static let red: [Color] = [Color(hex: 0xFF7A6B), Color(hex: 0xDE2F1F)]
    static let teal: [Color] = [Color(hex: 0x38D6C4), Color(hex: 0x0E9A8C)]
    static let gray: [Color] = [Color(hex: 0xA9B2BA), Color(hex: 0x6E7780)]
}

/// 设置行：图标 + 标题（可带副标题）+ 右侧值 + 箭头
struct PanelRow: View {
    var symbol: String
    var colors: [Color] = PanelTint.green
    var title: String
    var subtitle: String? = nil
    var value: String? = nil
    var chevron: Bool = true
    var tap: () -> Void

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 11) {
                PanelIcon(symbol: symbol, colors: colors)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(pf(16))
                        .foregroundColor(C.label)
                        .lineLimit(1)
                    if let s = subtitle, !s.isEmpty {
                        Text(s)
                            .font(pf(12.5))
                            .foregroundColor(C.subLabel)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let v = value, !v.isEmpty {
                    Text(v)
                        .font(pf(15))
                        .foregroundColor(C.subLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if chevron { Chevron(size: 9, line: 1.6) }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 开关行：图标 + 标题 + 右侧开关
struct PanelToggleRow: View {
    var symbol: String
    var colors: [Color] = PanelTint.green
    var title: String
    var subtitle: String? = nil
    var isOn: Bool
    var onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 11) {
            PanelIcon(symbol: symbol, colors: colors)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(pf(16))
                    .foregroundColor(C.label)
                if let s = subtitle, !s.isEmpty {
                    Text(s)
                        .font(pf(12.5))
                        .foregroundColor(C.subLabel)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { isOn }, set: { onChange($0) }))
                .labelsHidden()
                .tint(C.green)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
    }
}

/// 危险行：清空记录 / 删除 / 退群 / 删除好友（红字）
struct PanelDangerRow: View {
    var symbol: String
    var title: String
    var tap: () -> Void

    /// 危险动作的红：浅色模式下 #FA5151 压在白卡上偏"粉"、看着发灰，
    /// 这里用更实的红（浅 #E03A3A / 深 #FF6B6B），一眼能看清。
    private var dangerInk: Color { Color.dyn(0xE03A3A, 0xFF6B6B) }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 11) {
                PanelIcon(symbol: symbol, colors: PanelTint.red, size: 28)
                Text(title)
                    .font(pf(16))
                    .foregroundColor(dangerInk)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 卡片里那种小圆玻璃按钮（群成员右上角的「＋ / －」）
/// 微信那种**居中确认框**（自己画，不用系统 confirmationDialog ——
/// 系统那个标题又小又灰，用户反馈「移出群聊看不清」）。
/// 排版照微信：白卡 12 圆角、标题 17pt 深色居中、两条横线分隔的按钮（危险动作红字）。
struct PanelConfirmDialog: View {
    var title: String
    var okText: String
    /// 危险动作（移出群聊 / 退出群聊 / 清空记录）→ 按钮用红字
    var danger: Bool = true
    var onOk: () -> Void
    var onCancel: () -> Void

    private var okColor: Color {
        danger ? Color.dyn(0xE03A3A, 0xFF6B6B) : C.green
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }
            VStack(spacing: 0) {
                Text(title)
                    .font(pf(16.5, .medium))
                    .foregroundColor(C.label)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 24)
                    .frame(minWidth: 250)
                Rectangle().fill(C.hairline).frame(height: 0.5)
                HStack(spacing: 0) {
                    Button { onCancel() } label: {
                        Text(Tr("取消"))
                            .font(pf(16.5))
                            .foregroundColor(C.label)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(C.hairline).frame(width: 0.5, height: 50)
                    Button { onOk() } label: {
                        Text(okText)
                            .font(pf(16.5, .semibold))
                            .foregroundColor(okColor)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(C.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(width: 272)
            .shadow(color: Color.black.opacity(0.22), radius: 22, y: 8)
        }
    }
}

struct PanelCircleButton: View {
    var symbol: String
    var tint: Color = C.label
    var tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(C.pageBg.opacity(0.9))
                )
                .overlay(Circle().stroke(C.hairline, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }
}

/// 行与行之间的分隔线（对齐到图标右边，不是从最左边拉过来）
struct PanelDivider: View {
    var body: some View { HairLine(inset: 55) }
}
