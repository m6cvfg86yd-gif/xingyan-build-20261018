import SwiftUI

/* 我们自己的启动页：铺满整屏显示 splash.png，进来盖 1 秒后淡出。
   图片打包在 App 里（CI 会把 splash.png 拷进 bundle），不走网络，
   所以断网、冷启动都能立刻显示。
   2026-09-25：改成「铺满（cover）」——和微信一样整屏顶满，不再上下留色带。 */
struct SplashView: View {
    /// 后台配的启动页图片（后台「界面配置」里换）；空着就用包里那张
    var remote: String = ""

    var body: some View {
        /* 用 GeometryReader 拿"整块窗口"的真实尺寸（含状态栏/刘海那一条），
           再用 ignoresSafeArea 铺出去 —— 之前用 UIScreen 尺寸在安全区里布局，
           顶部会留 ~13pt 露出页面底色，看着就是一条白条。 */
        GeometryReader { geo in
            ZStack {
                Color.black
                /* 优先用后台配的那张（远端图，带缓存）：换图不用重装 App。
                   没配、或者还没下载完 → 下面用包里那张兜底，保证冷启动/断网都不白屏。 */
                if !remote.isEmpty {
                    /* 底下垫一层放大+模糊的同图：极窄/极宽的屏幕（iPad、老 16:9）上
                       cover 也裁不出东西时，兜住边角，不会露黑边。 */
                    RemoteImage(path: remote, mode: .fill, maxSide: 1600)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 26)
                        .clipped()
                    /* 主图：铺满（cover）。图本身按手机比例（1290×2796）出的，
                       所以只会裁掉极边缘一点，主体（星球）居中不受影响。 */
                    RemoteImage(path: remote, mode: .fill, maxSide: 2560)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if let img = UIImage(named: "splash") {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 26)
                        .clipped()
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "message.fill")
                            .font(.system(size: 54))
                            .foregroundColor(.white)
                        Text("Luchat")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea(.all)
    }
}