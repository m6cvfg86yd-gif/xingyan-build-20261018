import SwiftUI

/* ============================================================
   我的二维码：每个人一张，别人扫了就能加你好友
   （「我」页面头像右上角那个二维码小图标进来的就是这一页）
   ============================================================ */
/* 旧版（浅色卡片那版）：已被 MyQRNew.swift 里的新版替换，界面不再用它。
   注意：旧版「保存到相册」把头像盖在二维码正中间 —— 这套码是纠错等级 L，
   盖住 23% 就扫不出来了，新版已经改成头像放在码下面。 */
struct MyQRViewOld: View {
    @ObservedObject private var lang = LangStore.shared
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [String] = []
    @State private var code = ""
    @State private var name = ""
    @State private var username = ""
    @State private var avatar = ""
    @State private var loading = true
    @State private var saved = false
    @State private var showScan = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("我的二维码"), back: { dismiss() }) {
                Button {
                    saveToAlbum()
                } label: {
                    Text(saved ? Tr("已存") : Tr("保存"))
                        .font(pf(16, .medium))
                        .foregroundColor(rows.isEmpty ? C.subLabel : C.green)
                        .frame(height: L.navH)
                        .padding(.trailing, 16)
                }
                .buttonStyle(.plain)
                .disabled(rows.isEmpty)
            }

            ScrollView {
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Color.white)
                        if loading {
                            ProgressView()
                        } else if rows.isEmpty {
                            Text(Tr("二维码生成失败，稍后再试"))
                                .font(pf(13.5)).foregroundColor(C.subLabel)
                        } else {
                            /* 中间**不能**再盖头像了。
                               服务器这套二维码编码器是纠错等级 L（只容忍 7% 破损），
                               原来在正中间盖一个 44pt 的头像（占码宽 23%）＝ 把码毁掉：
                               实测「不盖头像能扫出来、按原样盖头像完全扫不出来」。
                               微信敢盖是因为它用纠错 H（30%）。这里改成：二维码保持干净，
                               头像放到下面那张个人信息卡里（照样一眼认人）。 */
                            QRCanvas(rows: rows).frame(width: 228, height: 228)
                                .frame(width: 228, height: 228)
                        }
                    }
                    .frame(width: 256, height: 256)
                    .shadow(color: Color.black.opacity(0.08), radius: 12, y: 4)

                    HStack(spacing: 12) {
                        Avatar(path: avatar, size: 46, radius: 6)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(pf(16, .medium)).foregroundColor(C.label).lineLimit(1)
                            Text(Tr("星言号：") + (username.isEmpty ? "-" : username))
                                .font(pf(12.5)).foregroundColor(C.subLabel)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 68)
                    .background { CardGlassBox(radius: 7) }
                    .padding(.horizontal, 24)

                    Text(Tr("用 App 的「发现 → 扫一扫」扫这张，就能加我好友"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)

                    Button {
                        showScan = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "qrcode.viewfinder")
                            Text(Tr("扫一扫"))
                        }
                        .font(pf(15, .medium))
                        .foregroundColor(C.green)
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .background { CardGlassBox(radius: 999) }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    Spacer().frame(height: 30)
                }
                .padding(.top, 20)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        /* 微信那一下「突然调亮」：进这一页把屏幕亮度拉到 100%，退出还原 —— 对方/扫码枪才扫得出来 */
        .modifier(BrightenScreen())
        .fullScreenCover(isPresented: $showScan) {
            ScannerView { text in handleScanned(text, app: app) }
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

    private func saveToAlbum() {
        guard !rows.isEmpty else { return }
        let card = VStack(spacing: 14) {
            ZStack {
                QRCanvas(rows: rows).frame(width: 520, height: 520)
                Avatar(path: avatar, size: 100, radius: 18)
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 24).fill(Color.white))
            }
            .frame(width: 520, height: 520)
            Text(name).font(.system(size: 26, weight: .semibold))
            Text(Tr("星言号：") + username).font(.system(size: 20)).foregroundColor(.gray)
            Text(Tr("扫一扫，加我好友")).font(.system(size: 20)).foregroundColor(.gray)
        }
        .padding(40)
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
