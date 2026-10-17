import SwiftUI

/* ============================================================
   商城开屏广告页（2026-10-17 用户：「布置下商城开屏3秒广告封面页可以跳过，
   给管理接上，你不要放图」）

   规则（和京东/微信开屏广告一致）：
     · 打开商城时整屏封面，右上角「跳过 3」倒计时，点一下立刻关
     · 到点自己关，不用用户操作
     · 封面**只有管理端配了才显示**（App 里：管理 → 商城后台 → 开屏广告 →
       上传封面）；没配就完全不弹 —— 代码里不带任何图
     · 点封面去哪由后台定：不跳 / 网址 / 某个商品
   ============================================================ */
struct MallSplashAdView: View {
    let splash: DDSplash
    /// 关掉（跳过 / 倒计时到点）
    var onClose: () -> Void
    /// 点了封面
    var onTap: () -> Void

    /// 还剩几秒
    @State private var left: Double = 3
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black

            /* 封面：**任意比例的图都好看**（2026-10-17 用户：「这个商城开屏广告图怎么不匹配的」）——
               后台那张图是 988×1280（4:5 竖图），而手机屏是 9:19.5；老写法 `scaledToFill`
               按短边铺满、两边各裁掉一大截，主体和文案直接被切没了，看着就是"图不匹配"。
               现在照大厂那套：**模糊铺满当底 + 原图等比完整居中** —— 什么比例的创意摆上去
               都像专门为这个屏做的（底下那层压 30% 黑，白字才压得住）。
               想回到老式的"满屏裁切"：后台 ui.json 写 splashFit = 0。 */
            GeometryReader { geo in
                let fit = UIConfig.num("splashFit", 1) > 0
                ZStack {
                    RemoteImage(path: splash.image ?? "", icon: "photo")
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: fit ? 26 : 0)
                    if fit {
                        Color.black.opacity(0.30)
                        RemoteImage(path: splash.image ?? "", icon: "photo", mode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            /* 跳过（右上角） */
            Button { onClose() } label: {
                /* 2026-10-17 用户：「没有 3 2 1 吗」——
                   倒计时本来就在（就是「跳过 3」里那个数字，每秒 3→2→1），
                   但太小、容易被当成静态文字。现在做成**一圈会走的倒计时环**：
                   外圈白环在这几秒里从满圈走到空圈，环里是那个数字（等宽，1 秒跳一格），
                   右边才是「跳过」两字 —— 一眼看出"还剩几秒、点一下能跳"（京东/淘宝开屏同款）。 */
                HStack(spacing: 6) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.30), lineWidth: 1.6)
                        Circle()
                            .trim(from: 0, to: max(0.001, min(1, left / max(1, splash.secs))))
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: left)
                        Text(String(Int(ceil(max(0, left)))))
                            .font(pf(10.5, .semibold)).monospacedDigit()
                            .foregroundColor(.white)
                    }
                    .frame(width: 18, height: 18)
                    Text(splash.skip).font(pf(13)).foregroundColor(.white)
                }
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(Capsule().fill(Color.black.opacity(0.38)))
                .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 0.6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
            .padding(.top, L.safeTop + 8)

            /* 底下那一行：广告标 + 提示 */
            VStack {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(Tr("广告"))
                        .font(pf(10.5))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.18)))
                    Text(Tr("点封面可以去看看"))
                        .font(pf(11)).foregroundColor(.white.opacity(0.6))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, L.safeBottom + 12)
            }
        }
        .ignoresSafeArea()
        .onAppear { left = splash.secs }
        .onReceive(ticker) { _ in
            left -= 1
            if left <= 0.01 { onClose() }
        }
    }
}
