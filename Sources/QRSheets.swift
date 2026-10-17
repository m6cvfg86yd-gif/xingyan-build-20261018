import SwiftUI

/* ============================================================
   「我的二维码」下面那两排点开的两层（2026-10-12 加）

     · QRStyleSheet        —— 换个样式：绿 / 蓝 / 红 / 黄 / 紫 / 黑
     · FaceToFaceFileSheet —— 面对面收照片和文件：把自己的码给对方扫，
                              对方加你为好友后当面把照片、文件发过来（收到的都进聊天）

   （「面对面收红包」直接出示收款码那一页，见 MyQRView 里的 PayCodePage。）
   ============================================================ */

struct QRStyleSheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: QRInk
    let onPick: (QRInk) -> Void

    private let cols = [GridItem(.adaptive(minimum: 76), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("换个样式"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Tr("挑一个颜色，二维码和「保存到相册」的图片都会用这个色（白底上用深色才扫得出来）。"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .padding(.horizontal, 20).padding(.top, 12)

                    LazyVGrid(columns: cols, spacing: 14) {
                        ForEach(QRInk.allCases, id: \.rawValue) { ink in
                            Button {
                                onPick(ink)
                                dismiss()
                            } label: {
                                VStack(spacing: 8) {
                                    ZStack {
                                        Circle().fill(ink.color).frame(width: 52, height: 52)
                                        if ink == current {
                                            Circle().stroke(C.green, lineWidth: 2.5)
                                                .frame(width: 60, height: 60)
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 18, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    }
                                    .frame(width: 62, height: 62)
                                    Text(Tr(ink.name)).font(pf(13.5))
                                        .foregroundColor(ink == current ? C.green : C.label)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
    }
}

struct FaceToFaceFileSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let rows: [String]
    let avatar: String
    let name: String
    var ink: Color = .black

    @State private var showScan = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("面对面收照片和文件"), back: { dismiss() })
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Text(Tr("让对方用 App 的「发现 → 扫一扫」扫下面这张码"))
                        .font(pf(13.5)).foregroundColor(C.subLabel)
                        .padding(.top, 16)

                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white)
                        if rows.isEmpty {
                            ProgressView()
                        } else {
                            QRCanvas(rows: rows, avatar: avatar, ink: ink)
                                .frame(width: 200, height: 200)
                        }
                    }
                    .frame(width: 236, height: 236)
                    .shadow(color: Color.black.opacity(0.07), radius: 10, y: 3)
                    .padding(.top, 14)

                    HStack(spacing: 8) {
                        Avatar(path: avatar, size: 28, radius: 14, circle: true)
                        Text(name.isEmpty ? Tr("我") : name)
                            .font(pf(15, .medium)).foregroundColor(C.label)
                    }
                    .padding(.top, 10)

                    GroupCard {
                        VStack(alignment: .leading, spacing: 8) {
                            hintRow("1", Tr("对方扫码后加你为好友（对方的会话列表里会出现你）"))
                            hintRow("2", Tr("在会话里点「＋ → 照片 / 文件」当面发过来"))
                            hintRow("3", Tr("收到的照片、文件都会留在你们的聊天记录里"))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                    }
                    .padding(.top, 16)

                    Button { showScan = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "qrcode.viewfinder").font(.system(size: 16))
                            Text(Tr("我也扫对方的码（对着发也行）")).font(pf(16, .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.green))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 12)

                    Spacer().frame(height: 30)
                }
                .padding(.horizontal, 20)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        /* 这一页也是给对方扫的（面对面收照片和文件）：进来渐亮、退出还原 */
        .modifier(BrightenScreen())
        .fullScreenCover(isPresented: $showScan) {
            ScannerView { text in handleScanned(text, app: app) }
        }
    }

    private func hintRow(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(C.green.opacity(0.16)).frame(width: 20, height: 20)
                Text(n).font(.system(size: 11, weight: .semibold)).foregroundColor(C.green)
            }
            Text(text).font(pf(13.5)).foregroundColor(C.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
