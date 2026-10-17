import SwiftUI
import WebKit

/* ============================================================
   拼多多风格 H5 商城（2026-10-12 接入，入口在「我 → 小店与卡包」）

   H5 本身是纯前端（商品 / 购物车 / 订单都放 localStorage，和商城后台 admin.html
   共用同一套数据），已经放在服务器 public/mall/ 下：
     · 商城首页  /mall/index.html
     · 商城后台  /mall/admin.html
   好处是**改商城不用重新出包**，服务器换了文件 App 里刷新一下就是新的。

   ⚠ 我们的服务器是 IP + 自签证书：WKWebView 默认不认，页面会直接加载失败
   （和「小游戏打不开」是同一个坑）。所以这里的 WebView 自带一个导航代理，
   对上我们服务器的 serverTrust 直接放行。
   ============================================================ */

struct MallWebPage: View {
    @Environment(\.dismiss) private var dismiss

    /// 相对路径（默认商城首页；传 /mall/admin.html 就是后台）
    var path: String = "/mall/index.html"
    var title: String = "拼多多商城"

    @State private var reloadTick = 0
    @State private var loading = true

    private var url: URL? {
        URL(string: API.shared.base + path + (path.contains("?") ? "&" : "?") + "v=\(reloadTick)")
    }

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr(title), back: { dismiss() }) {
                Button {
                    reloadTick += 1
                    loading = true
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(C.label)
                        .frame(width: 40, height: 32)
                }
                .buttonStyle(.plain)
            }
            ZStack(alignment: .top) {
                if let u = url {
                    MallWebView(url: u, tick: reloadTick, loading: $loading)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    Text(Tr("商城地址不对")).font(pf(14)).foregroundColor(C.subLabel)
                }
                if loading {
                    ProgressView().padding(.top, 24)
                }
            }
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
    }
}

/// WKWebView + 放行我们服务器的自签证书
struct MallWebView: UIViewRepresentable {
    let url: URL
    /// 变了就重新加载（顶栏那颗刷新）
    let tick: Int
    @Binding var loading: Bool

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.bounces = false
        v.scrollView.contentInsetAdjustmentBehavior = .never
        v.load(URLRequest(url: url))
        context.coordinator.lastTick = tick
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        /* 顶栏那颗刷新：tick 一变就重新 load ✓（别用 reload()，
           我们用 tick 拼在 URL 上，能绕开 WebView 自己的缓存） */
        if context.coordinator.lastTick != tick {
            context.coordinator.lastTick = tick
            v.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(loading: $loading) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastTick = 0
        let loading: Binding<Bool>
        init(loading: Binding<Bool>) { self.loading = loading }

        /// 自签证书放行（只放我们自己的服务器；别的域名走系统默认校验）
        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                   URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.loading.wrappedValue = false }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.loading.wrappedValue = false }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            DispatchQueue.main.async { self.loading.wrappedValue = false }
        }
    }
}
