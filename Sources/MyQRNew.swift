import SwiftUI

/* ============================================================
   我的二维码（2026-10-12 按用户要求改成**微信扫一扫那种排版**）

   从上到下：
     ① 头像 + 昵称 + 星言号
     ② 一张白底大二维码（小头像摆正中间；服务器出的码是纠错等级 H，挡一小块照样扫得出来）
        —— 支持**换样式**：绿 / 蓝 / 红 / 黄 / 紫 / 黑，选完记住（@AppStorage），
           保存到相册的那张图也跟着变颜色。
     ③ 一行小字：扫一扫上面的二维码，加我为朋友
     ④ 底下**两排**（微信扫一扫页那个排版）：面对面收照片和文件 / 面对面收红包
                                       换个样式 / 保存到相册
   ============================================================ */

/// 二维码的六种颜色样式（都是深色，白底上扫得出来；黄用的是深琥珀，浅黄扫不出来）
enum QRInk: String, CaseIterable {
    case green, blue, red, amber, purple, black

    var name: String {
        switch self {
        case .green:  return "绿"
        case .blue:   return "蓝"
        case .red:    return "红"
        case .amber:  return "黄"
        case .purple: return "紫"
        case .black:  return "黑"
        }
    }
    var color: Color {
        switch self {
        case .green:  return Color(hexString: "#12A05A")
        case .blue:   return Color(hexString: "#1B5FD0")
        case .red:    return Color(hexString: "#D6353B")
        case .amber:  return Color(hexString: "#B4770F")
        case .purple: return Color(hexString: "#6A3FD0")
        case .black:  return Color(hexString: "#111111")
        }
    }
}

struct MyQRView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var growth = GrowthStore.shared

    @State private var rows: [String] = []
    @State private var code = ""
    @State private var name = ""
    @State private var username = ""
    @State private var avatar = ""
    @State private var loading = true
    @State private var saved = false
    @State private var showScan = false
    /// 换个样式（颜色）那一层
    @State private var showStyle = false
    /// 面对面收照片和文件
    @State private var showFaceFile = false
    /// 面对面收红包（出示收款码）
    @State private var showPayCode = false
    /// 选中的样式（记住，下次进来还是这个颜色）
    @AppStorage("qrInkStyle") private var inkID = QRInk.green.rawValue

    private var ink: QRInk { QRInk(rawValue: inkID) ?? .green }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("我的二维码"), back: { dismiss() })

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    /* ① 头像 + 昵称 + 星言号 */
                    VStack(spacing: 10) {
                        Avatar(path: avatar.isEmpty ? (app.me?.avatarPath ?? "") : avatar,
                               size: 62, radius: 31, circle: true, level: growth.shownLevel)
                        Text(name.isEmpty ? (app.me?.name ?? "") : name)
                            .font(pf(18, .medium))
                            .foregroundColor(C.label)
                            .lineLimit(1)
                        Text(Tr("星言号：") + (username.isEmpty ? "-" : username))
                            .font(pf(13))
                            .foregroundColor(C.subLabel)
                            .lineLimit(1)
                    }
                    .padding(.top, 22)
                    .padding(.bottom, 18)

                    /* ② 白底大二维码（小头像摆正中间，微信那种） */
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white)
                        if loading {
                            ProgressView()
                        } else if rows.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 22)).foregroundColor(C.subLabel)
                                Text(Tr("二维码生成失败，稍后再试"))
                                    .font(pf(13)).foregroundColor(C.subLabel)
                            }
                        } else {
                            QRCanvas(rows: rows, avatar: avatar, ink: ink.color)
                                .frame(width: 224, height: 224)
                        }
                    }
                    .frame(width: 264, height: 264)
                    .shadow(color: Color.black.opacity(0.07), radius: 10, y: 3)

                    /* ③ 一行小字 */
                    Text(Tr("扫一扫上面的二维码，加我为朋友"))
                        .font(pf(13))
                        .foregroundColor(C.subLabel)
                        .padding(.top, 14)

                    /* ④ 底下两排（微信扫一扫页那个排版）：上面两个「面对面」，下面换个样式 / 保存 */
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            qrTile(icon: "square.and.arrow.down.on.square", title: Tr("面对面收照片和文件"),
                                   sub: Tr("对方扫码当面发给你")) { showFaceFile = true }
                            qrTile(icon: "yensign.circle", title: Tr("面对面收红包"),
                                   sub: Tr("出示收款码收红包")) { showPayCode = true }
                        }
                        HStack(spacing: 10) {
                            qrTile(icon: "paintpalette", title: Tr("换个样式"),
                                   sub: ink.name + Tr("色")) { showStyle = true }
                            qrTile(icon: "arrow.down.to.line", title: saved ? Tr("已存到相册") : Tr("保存到相册"),
                                   sub: Tr("存成图片发给别人")) { saveToAlbum() }
                        }
                    }
                    .padding(.top, 18)

                    Spacer().frame(height: 30)
                }
                .padding(.horizontal, 16)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        /* 进「我的二维码」把屏幕**渐亮到最亮**，退出还原 —— 微信那一下（扫码枪才扫得出来）。
           ⚠ 之前 BrightenScreen 写好了却一个页面都没挂，所以用户反馈「点开没有变亮」。 */
        .modifier(BrightenScreen())
        .fullScreenCover(isPresented: $showScan) {
            ScannerView { text in handleScanned(text, app: app) }
        }
        /* 换个样式：绿 / 蓝 / 红 / 黄 / 紫 / 黑 */
        .sheet(isPresented: $showStyle) {
            QRStyleSheet(current: ink) { pick in
                inkID = pick.rawValue
                DiagLog.shared.note("二维码样式：" + pick.name)
            }
        }
        /* 面对面收照片和文件（给对方扫这张码） */
        .sheet(isPresented: $showFaceFile) {
            FaceToFaceFileSheet(rows: rows, avatar: avatar, name: name, ink: ink.color)
                .environmentObject(app)
        }
        /* 面对面收红包 = 出示收款码 */
        .sheet(isPresented: $showPayCode) {
            NavigationStack { PayCodePage() }
                .environmentObject(app)
        }
        .task {
            let r = await API.shared.myQRCode()
            code = r.code
            rows = r.rows
            name = r.user?.name ?? (app.me?.name ?? "")
            username = r.user?.username ?? (app.me?.username ?? "")
            avatar = r.user?.avatarPath ?? (app.me?.avatarPath ?? "")
            loading = false
        }
    }

    /* 底下那两排里的一个方块（微信扫一扫页底部的按钮就是这个样子：图标 + 标题 + 小字） */
    private func qrTile(icon: String, title: String, sub: String,
                        tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(C.green)
                    Text(title)
                        .font(pf(15, .medium))
                        .foregroundColor(C.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(sub)
                    .font(pf(11.5))
                    .foregroundColor(C.subLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 74)
            .background(C.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /* 保存到相册：一张干净的图（头像在码下面，不盖码） */
    private func saveToAlbum() {
        guard !rows.isEmpty else { return }
        let card = VStack(spacing: 16) {
            QRCanvas(rows: rows, avatar: avatar, ink: ink.color).frame(width: 520, height: 520)
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.white))
            HStack(spacing: 16) {
                Avatar(path: avatar, size: 84, radius: 42, circle: true, level: growth.shownLevel)
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(.system(size: 28, weight: .semibold)).foregroundColor(.black)
                    Text(Tr("星言号：") + username).font(.system(size: 20)).foregroundColor(.gray)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            Text(Tr("扫一扫，加我为好友")).font(.system(size: 20)).foregroundColor(.gray)
        }
        .padding(40)
        .frame(width: 640)
        .background(Color.white)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        if let img = renderer.uiImage {
            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
            saved = true
            app.show(Tr("二维码已存到相册"))
            return
        }
        app.show(Tr("保存失败，可以截图"))
    }
}

