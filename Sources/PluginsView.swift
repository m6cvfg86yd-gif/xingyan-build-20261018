import SwiftUI

/* ============================================================
   插件（我 → 插件）—— 2026-10-15 用户要求：
   「把眼睛可以开关做进插件类目里面……把设置里已经做的小星开关类删掉」

   所以：
     · 小星（会话页顶栏那双眼睛）的三档开关挪到这一页（点进去还是原来那页 EyesSettingsView）
     · 设置 → 通用 → 更多 里那一行「显示小星」已经删掉
     · 2026-10-16 用户要求「插件里面就只要小星」→ 这一页现在**只有小星一行**
       （听一听、小程序那两行删掉了；它们本身还在「发现」里，没丢功能）
   ============================================================ */

struct PluginsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var eyes = EyesStore.shared

    @State private var showEyes = false
    /// 2026-10-15 用户：「打开眼睛要人脸识别」——开小星之前先过一遍人脸核身
    @State private var showFaceForEyes = false

    /// 右边那行小字：小星现在是哪一档
    private var eyesValue: String {
        switch eyes.tier {
        case "off":    return Tr("已关闭")
        case "static": return Tr("静态")
        case "on":     return Tr("开启")
        default:       return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("插件"), back: { dismiss() }) { }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    /* 微信「插件」那一页的样子：一张白卡，一行一个插件 ——
                       左边图标 + 名字 + 下面一行灰说明，右边一颗**绿色开关**；
                       有开关的行**点名字那块**照样进它自己的设置页（微信也是这样）。 */
                    GroupCard {
                        switchRow(icon: "eye", tint: C.green,      // 2026-10-17：跟着主色走，不写死绿
                                  title: Tr("小星"),
                                  sub: eyes.eyesOn
                                       ? Tr("正在用：") + eyesValue + Tr("　会话页顶栏那双眼睛")
                                       : Tr("已关闭：会话页顶栏那儿空出来，放大镜顶上去"),
                                  isOn: eyes.eyesOn) { on in
                            if on {
                                /* 开之前先人脸核身（过了才真开；取消/没通过就保持关着） */
                                showFaceForEyes = true
                            } else {
                                Task { if let err = await eyes.set("off") { app.show(err) } }
                            }
                        } onOpen: { showEyes = true }
                        /* 2026-10-16 用户要求：「插件里面就只要小星，听一听和小程序不要」——
                           那两行已经删掉（听一听在「发现」里，小程序在「发现 → 小程序」里，都还在，
                           只是不再往插件页里塞）。 */
                    }
                    .padding(.horizontal, 12)

                    Text(Tr("小星的开关在这一页里。点名字可以进去调更细的档位（开启 / 静态 / 关闭）。"))
                        .font(pf(12)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                    Spacer().frame(height: 10)
                }
                .padding(.vertical, 10)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await eyes.refresh() }
        /* 开小星 = 先过人脸（两页那套：准备页 → 活体页；有 TrueDepth 的机型还查深度防假） */
        .sheet(isPresented: $showFaceForEyes) {
            FaceVerifyFlowView { ok in
                showFaceForEyes = false
                if ok {
                    Task {
                        /* 开启是 ¥40 一次性（走零钱）：余额不够就把原因弹出来 */
                        if let err = await eyes.set("on") { app.show(err) }
                        else { app.show(Tr("人脸验证通过，小星已打开")) }
                    }
                } else {
                    app.show(Tr("人脸验证没通过，小星先保持关闭"))
                }
            }
            .environmentObject(app)
        }
        .navigationDestination(isPresented: $showEyes) { EyesSettingsView() }
    }

    /// 带绿色开关的一行（微信插件页那种）
    private func switchRow(icon: String, tint: Color, title: String, sub: String,
                           isOn: Bool, onSet: @escaping (Bool) -> Void,
                           onOpen: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 17))
                        .foregroundColor(tint)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(pf(16)).foregroundColor(C.label)
                        Text(sub).font(pf(12.5)).foregroundColor(C.subLabel)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("", isOn: Binding(get: { isOn }, set: { onSet($0) }))
                .labelsHidden()
                .tint(C.green)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 66)
    }

    private func row(icon: String, tint: Color, title: String, sub: String,
                     value: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(pf(15.5)).foregroundColor(C.label)
                    Text(sub).font(pf(12)).foregroundColor(C.subLabel).lineLimit(1)
                }
                Spacer(minLength: 8)
                if !value.isEmpty {
                    Text(value).font(pf(13)).foregroundColor(C.subLabel)
                }
                Chevron(size: 9, line: 1.5)
            }
            .padding(.horizontal, 16)
            .frame(height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
