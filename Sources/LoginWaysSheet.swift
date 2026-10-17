import SwiftUI

/* ============================================================
   登录页「更多登录方式」面板（2026-10-12 照微信那套重做）

   微信的登录方式面板不是系统确认框，是一张从底下推上来的白卡：
     · 每项前面一个**彩色圆图标**（这就是用户说的「微信的几个色彩」）：
         人脸识别 = 微信绿 · 声音锁 = 橙 · 手机号 = 蓝 · 账号密码 = 靛
     · 标题「更多登录方式」+ 每行图标 / 名字 / 副标题 / 右箭头
     · 最下面单独一张「取消」卡
   ============================================================ */

struct LoginWaysSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onPhone: () -> Void
    let onPassword: () -> Void
    let onFace: () -> Void
    let onVoice: () -> Void
    /// 设备确认登录（扫一扫 / 输数字）。不传就不显示这一行。
    var onPair: (() -> Void)? = nil

    private struct Way: Identifiable {
        let id: String
        let title: String
        let sub: String
        let symbol: String
        let color: Color
    }

    private var ways: [Way] {
        var a: [Way] = [Way(id: "face", title: Tr("人脸识别登录"), sub: Tr("用面容直接进"), symbol: "faceid",
                            color: C.green),        // 2026-10-17：跟主色走，不再写死微信绿
                        Way(id: "voice", title: Tr("声音锁登录"), sub: Tr("读出屏幕上的数字"), symbol: "waveform",
                            color: Color(hex: 0xF59A1E)),
                        Way(id: "phone", title: Tr("手机号登录"), sub: Tr("短信验证码"), symbol: "phone.fill",
                            color: Color(hex: 0x3D83E7)),
                        Way(id: "pass", title: Tr("账号密码登录"), sub: Tr("用用户名和密码"), symbol: "key.fill",
                            color: Color(hex: 0x5B6673))]
        if onPair != nil {
            a.append(Way(id: "pair", title: Tr("在另一台设备上确认登录"),
                         sub: Tr("扫码或输数字，和微信一样"), symbol: "qrcode.viewfinder",
                         color: Color(hex: 0x6366F1)))
        }
        return a
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 8) {
                VStack(spacing: 0) {
                    Text(Tr("更多登录方式"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                    ForEach(ways) { w in
                        HairLine(inset: 16)
                        Button {
                            dismiss()
                            /* 稍微等一下再关：面板收起来的动画先走完，再打开下一层，
                               免得两个弹层打架（真机上会静默不弹）。 */
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                switch w.id {
                                case "face":  onFace()
                                case "voice": onVoice()
                                case "phone": onPhone()
                                case "pair":  onPair?()
                                default:      onPassword()
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(w.color)
                                    Image(systemName: w.symbol)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                .frame(width: 34, height: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(w.title).font(pf(16.5)).foregroundColor(C.label)
                                    Text(w.sub).font(pf(12)).foregroundColor(C.subLabel)
                                }
                                Spacer(minLength: 0)
                                Chevron(size: 9, line: 1.6)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 62)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MenuPressStyle())
                    }
                }
                .background(C.cardBg)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button { dismiss() } label: {
                    Text(Tr("取消"))
                        .font(pf(17)).foregroundColor(C.label)
                        .frame(maxWidth: .infinity).frame(height: 56)
                        .background(C.cardBg)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, max(10, L.safeBottom))
        }
        .presentationDetents([.height(CGFloat(46 + 62 * ways.count) + 56 + 8 + 18 + L.safeBottom)])
        .presentationDragIndicator(.hidden)
    }
}
