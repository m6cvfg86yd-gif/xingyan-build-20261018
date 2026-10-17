import SwiftUI

/* ============================================================
   会动的「我」页图标（原生动效，不是 GIF）

   微信那种配色 + 三处动效：
     ① 呼吸：整块轻微起伏（1.8 秒一个来回）
     ② 扫光：一道斜向高光每隔 2.6 秒从左边扫到右边（像玻璃反光）
     ③ 按下：手指按住时轻微回弹（MenuRow 的按钮样式负责）

   为什么不用 GIF/APNG：iOS 的 Image 不会播 GIF（只显示第一帧），
   要做成能动的要么加个 GIF 视图、要么原生画 —— 原生画是 60fps、离线可用、还能跟
   系统动画/深色模式一起走，所以选原生。

   服务端下发的图标字段写 `anim:service` 这样就行；老版本 App 拿到这个字段
   会显示成一串字，所以服务端按版本回落成静态图（见 /api/me-page 里的 ANIM_MIN）。
   ============================================================ */

enum MenuIconKind: String {
    case service, favorites, moments, works, stickers, settings
    /// 发现页（视界）那几个 —— 和「我」页共用同一套线条图标
    case channels, live, shake, nearby, starworld, game, scan, look, searchrow
    /// 「我」页照微信补的两行：小店与卡包、插件
    case shop, plugins

    /// 渐变底色（浅 → 深）
    var colors: (Color, Color) {
        switch self {
        case .service:   return (Color(hex: 0x5ED07F), Color(hex: 0x2FA85C))
        case .favorites: return (Color(hex: 0xFFC94B), Color(hex: 0xF0A020))
        case .moments:   return (Color(hex: 0x4EC3A6), Color(hex: 0x22997E))
        case .works:     return (Color(hex: 0x5AA0F2), Color(hex: 0x2C6FD1))
        case .stickers:  return (Color(hex: 0xFFD75E), Color(hex: 0xF5A623))
        case .settings:  return (Color(hex: 0x8E9AA8), Color(hex: 0x5B6673))
        case .channels:  return (Color(hex: 0xFF8A5C), Color(hex: 0xE0652A))
        case .live:      return (Color(hex: 0xFF6B6B), Color(hex: 0xD93A3A))
        case .shake:     return (Color(hex: 0x5AA0F2), Color(hex: 0x2C6FD1))
        case .nearby:    return (Color(hex: 0x4EC97A), Color(hex: 0x22995A))
        case .starworld: return (Color(hex: 0x6B7BFF), Color(hex: 0x3B4CE0))
        case .game:      return (Color(hex: 0xA96BF6), Color(hex: 0x7A3ED6))
        case .scan:      return (Color(hex: 0x5AA0F2), Color(hex: 0x2C6FD1))
        case .look:      return (Color(hex: 0xFFB74A), Color(hex: 0xE08A10))
        case .searchrow: return (Color(hex: 0x8E9AA8), Color(hex: 0x5B6673))
        case .shop:      return (Color(hex: 0xFFC24B), Color(hex: 0xE08A22))
        case .plugins:   return (Color(hex: 0x8E9AA8), Color(hex: 0x5B6673))
        }
    }

    /// 图形：**线条勾勒款**（用户要求"用线条勾勒的 ui 图标，简单大气"）
    /// —— 所以这里一律用 SF Symbols 的 outline 版（不带 .fill），一根干净的线。
    var symbol: String {
        switch self {
        case .service:   return "wallet.pass"
        case .favorites: return "star"
        case .moments:   return "photo"
        case .works:     return "play.rectangle"
        case .stickers:  return "face.smiling"
        case .settings:  return "gearshape"
        /* 发现页那几个（同样是 outline 版，一根线） */
        case .channels:  return "play.rectangle"
        case .live:      return "dot.radiowaves.left.and.right"
        case .shake:     return "gyroscope"
        case .nearby:    return "location"
        case .starworld: return "globe"
        case .game:      return "gamecontroller"
        case .scan:      return "qrcode.viewfinder"
        case .look:      return "eye"
        case .searchrow: return "magnifyingglass"
        case .shop:      return "bag"
        case .plugins:   return "puzzlepiece"
        }
    }
}

struct AnimatedMenuIcon: View {
    let kind: MenuIconKind
    var size: CGFloat = 22

    @State private var breathe = false
    @State private var sweeping = false

    private var radius: CGFloat { size * 0.28 }

    var body: some View {
        /* 线条勾勒款（用户要求：用线条勾勒的 UI 图标，简单大气）：
           **不要底块**，就是一根干净的线 + 各自的颜色。
           线比实心块"轻"，但细线条在小尺寸上会发虚，所以给一点点描边感
           （同一根线画两遍、错开半像素）——远看干净，近看不毛。 */
        ZStack {
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.86, weight: .regular))
                .foregroundColor(kind.colors.1)
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.86, weight: .regular))
                .foregroundColor(kind.colors.1)
                .offset(x: 0.35, y: 0.35)
                .opacity(0.55)
        }
        .frame(width: size, height: size)
    }
}
