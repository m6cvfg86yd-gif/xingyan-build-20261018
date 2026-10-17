import SwiftUI

/* ============================================================
   右上角「＋」下拉小卡片（会话页 / 星联通讯录页共用）
   · 毛玻璃底 + 细描边 + 投影，从上右角缩放淡入
   · 每行：彩色渐变圆角图标 + 白图标 + 标题；行间细分割线；按下轻微缩小
   · 点卡片外面任何地方收起
   ============================================================ */

struct NavPlusItem {
    var title: String
    var symbol: String
    var colors: [Color]
    var action: () -> Void
}

struct NavPlusCard: View {
    var items: [NavPlusItem]
    /// 点某一行时先收起卡片，再执行动作
    var onPick: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                if idx > 0 { HairLine(inset: 46) }
                Button {
                    onPick()
                    item.action()
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(LinearGradient(colors: item.colors,
                                                     startPoint: .topLeading,
                                                     endPoint: .bottomTrailing))
                                .frame(width: 30, height: 30)
                                .shadow(color: item.colors.count > 1 ? item.colors[1].opacity(0.30) : .clear,
                                        radius: 5, y: 2)
                            Image(systemName: item.symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        Text(item.title).font(pf(15)).foregroundColor(C.label)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(NavPlusRowPressStyle())
            }
        }
        .frame(width: 178)
        /* 卡片也是玻璃（和顶栏/底栏/输入框同一套）：真玻璃底 + 一道上亮下淡的边 + 一点投影。
           它是个浮层、不在滚动列表里，所以直接走 iOS 26 的原生玻璃。
           想更透/更实：后台 ui.json 的 plusCardAlpha（越小越透，默认 0.9）。 */
        .background {
            GlassBackground(shape: RoundedRectangle(cornerRadius: 15, style: .continuous),
                            opacity: UIConfig.num("plusCardAlpha", 0.9),
                            edgeAlpha: UIConfig.num("plusCardEdge", 0.30),
                            shadow: false,
                            seed: 0.75,
                            native: true)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.26), lineWidth: 0.6)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 16, y: 8)
    }
}

private struct NavPlusRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .background(configuration.isPressed ? Color.black.opacity(0.05) : Color.clear)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// 把「＋」下拉卡片挂到当前页面上（整屏透明层 + 右上角卡片）
    @ViewBuilder
    func navPlusOverlay(_ show: Binding<Bool>, items: [NavPlusItem]) -> some View {
        overlay {
            if show.wrappedValue {
                /* ⚠ 位置**不能**靠"安全区 + 导航栏高度"猜着算：这层 overlay 挂在哪个视图上，
                   它的坐标原点就跟着那个视图走（有时在安全区内、有时是全屏），
                   猜错一次卡片就整整往下掉一条状态栏 —— 用户反馈的"离加号太远"就是这么来的。
                   现在改成**实测**：用 GeometryReader 拿到 overlay 顶部在屏幕上的真实 y，
                   再算出"要让卡片顶部落在屏幕的 安全区+导航栏 处，需要往下垫多少"。
                   这样不管挂在哪一层，卡片都正好贴在加号下面。
                   想微调：后台 plusCardTopGap（负数更往上贴，默认 -2）、plusCardRightGap（默认 10）。 */
                GeometryReader { g in
                    let overlayTop = g.frame(in: .global).minY
                    let want = L.safeTop + L.navH + UIConfig.num("plusCardTopGap", -2)
                    let padTop = max(0, want - overlayTop)
                    ZStack(alignment: .topTrailing) {
                        /* 透明层：点哪儿都能收起（不用变暗，微信也不变暗） */
                        Color.black.opacity(0.001)
                            .ignoresSafeArea()
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.14)) { show.wrappedValue = false }
                            }
                        NavPlusCard(items: items) {
                            withAnimation(.easeOut(duration: 0.12)) { show.wrappedValue = false }
                        }
                        .padding(.top, padTop)
                        .padding(.trailing, UIConfig.num("plusCardRightGap", 10))
                        /* 「弹出的感觉」（用户要求）：从右上角那个 ＋ 的位置**小尺寸弹出来**，
                           配上带一点回弹的弹簧（弹性由外面开卡片时的 withAnimation 决定）。
                           原来是从 0.86 淡进来，几乎是"浮现"，看不出是弹出来的。 */
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.42, anchor: .topTrailing)
                                .combined(with: .opacity)
                                .combined(with: .offset(y: -10)),
                            removal: .scale(scale: 0.92, anchor: .topTrailing)
                                .combined(with: .opacity)
                        ))
                    }
                }
            }
        }
    }
}
