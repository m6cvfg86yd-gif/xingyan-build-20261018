import SwiftUI

/* ============================================================
   好友名片 · 新版（畅聊 / HarmonyOS 设计语言）
   令牌：品牌蓝 #007DFF、文字 #181818/#666/#999、底 #FFFFFF/#F5F6F7、
        分隔 #E8EAED、圆角 8/12/16/胶囊、阴影 #20000000、间距 4 的倍数
   开关：后台 ui.json 里 cardStyle = "new" 才用这一版；默认 "old" 就是原来那版
   ============================================================ */

private let hBlue   = Color(hex: 0x007DFF)
private let hBlueBg = Color(hex: 0xE8F3FF)
private let hInk    = Color(hex: 0x181818)
private let hInk2   = Color(hex: 0x666666)
private let hInk3   = Color(hex: 0x999999)
private let hBg     = Color(hex: 0xF5F6F7)
private let hLine   = Color(hex: 0xE8EAED)
private let hGreen  = Color(hex: 0x2E7D32)

struct ContactCardNew: View {
    let name: String
    let idLine: String
    /// 头像（真人用图片，眼睛机器人用会动的眼睛）
    let avatarPath: String
    let isEyes: Bool
    let remark: String
    let phone: String
    let momentCount: Int
    /// 对方设的朋友圈可见范围（3d / 6m / all）：这区间里没动态时，
    /// 那一行要写微信那句「朋友仅展示最近三天的朋友圈」，不是「暂无朋友圈动态」。
    let momentsRange: String
    let onClose: () -> Void
    let onMessage: () -> Void
    let onVoice: () -> Void
    let onVideo: () -> Void
    let onMoments: (() -> Void)?

    var body: some View {
        ZStack(alignment: .top) {
            hBg.ignoresSafeArea()
            VStack(spacing: 0) {
                nav
                ScrollView {
                    VStack(spacing: 0) {
                        hero
                        if !detailRows.isEmpty {
                            sectionTitle("资料")
                            card {
                                ForEach(Array(detailRows.enumerated()), id: \.offset) { idx, row in
                                    if idx > 0 { line }
                                    hRow(row.0, row.1)
                                }
                            }
                        }
                        /* 朋友圈这一块一直在（朋友没发动态就写「暂无动态」），跟原来那版一致 */
                        sectionTitle("朋友圈", trailing: momentCount > 0 ? "\(momentCount) 条" : "")
                            card {
                                Button {
                                    onMoments?()
                                } label: {
                                    HStack(spacing: 12) {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(hBlueBg)
                                            .frame(width: 44, height: 44)
                                            .overlay(Image(systemName: "photo.on.rectangle.angled")
                                                .font(.system(size: 18)).foregroundColor(hBlue))
                        Text(momentCount > 0 ? "看 TA 的朋友圈" : momentEmptyText)
                            .font(pf(16)).foregroundColor(momentCount > 0 ? hInk : hInk3)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold)).foregroundColor(hInk3)
                                    }
                                    .padding(.horizontal, 16).frame(height: 60)
                                }
                                .buttonStyle(.plain)
                            }
                        Spacer(minLength: 24)
                    }
                }
            }
        }
    }

    private var detailRows: [(String, String)] {
        var list: [(String, String)] = []
        if !remark.isEmpty { list.append(("备注", remark)) }
        if !phone.isEmpty { list.append(("手机号", phone)) }
        return list
    }

    /// 朋友圈那一行没动态时写什么：
    /// 对方设了「最近三天 / 最近半年」→ 微信写的是「朋友仅展示最近三天的朋友圈」；
    /// 没设范围（all）才是「暂无朋友圈动态」。
    private var momentEmptyText: String {
        switch momentsRange {
        case "3d": return "朋友仅展示最近三天的朋友圈"
        case "6m": return "朋友仅展示最近半年的朋友圈"
        default:   return "暂无朋友圈动态"
        }
    }

    private var nav: some View {
        HStack {
            Button { onClose() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold)).foregroundColor(hInk)
            }
            .buttonStyle(.plain)
            Spacer()
            Text(name).font(pf(17, .semibold)).foregroundColor(hInk)
            Spacer()
            Image(systemName: "ellipsis").font(.system(size: 17)).foregroundColor(hInk)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.white)
    }

    private var hero: some View {
        VStack(spacing: 0) {
            /* 好友名片是「人名卡」：头像在左、名字和微信号在右，跟官方号的居中大 logo 区分开 */
            HStack(alignment: .center, spacing: 16) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if isEyes {
                            JarvisEyesAvatar(size: 72)
                        } else {
                            Avatar(path: avatarPath, size: 72, radius: 36)
                        }
                    }
                    .frame(width: 72, height: 72)
                    Circle().fill(hGreen).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(pf(20, .semibold)).foregroundColor(hInk)
                    Text(idLine).font(pf(14)).foregroundColor(hInk3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 16)
            /* 三枚按钮：发消息（主）· 语音通话 · 视频通话（次）—— 和原来那版一样多 */
            HStack(spacing: 10) {
                pill("发消息", primary: true, action: onMessage)
                pill("语音", primary: false, action: onVoice)
                pill("视频", primary: false, action: onVideo)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color(hex: 0x20000000), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func sectionTitle(_ t: String, trailing: String? = nil) -> some View {
        HStack {
            Text(t).font(pf(18, .medium)).foregroundColor(hInk)
            Spacer()
            if let tr = trailing { Text(tr).font(pf(14)).foregroundColor(hInk3) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color(hex: 0x20000000), radius: 8, x: 0, y: 2)
            .padding(.horizontal, 16)
    }

    private func hRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(pf(16)).foregroundColor(hInk)
            Spacer()
            Text(v).font(pf(14)).foregroundColor(hInk3)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private var line: some View {
        Rectangle().fill(hLine).frame(height: 1).padding(.leading, 16)
    }

    /// 胶囊按钮（主：品牌蓝底白字；次：品牌蓝描边）
    private func pill(_ text: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            Text(text)
                .font(pf(16, .medium))
                .foregroundColor(primary ? .white : hBlue)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    Group {
                        if primary { Capsule().fill(hBlue) } else { Capsule().stroke(hBlue, lineWidth: 1.5) }
                    }
                )
        }
        .buttonStyle(.plain)
    }
}
