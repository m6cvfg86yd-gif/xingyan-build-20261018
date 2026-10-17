import Foundation
import AVFoundation
import ObjectiveC

/// 让 AVPlayerItem 记住「伺候它的那个加载器」：item 被丢掉时能顺着它把请求掐掉。
private var chrisLoaderKey: UInt8 = 0
extension AVPlayerItem {
    fileprivate var chrisLoader: StreamLoader? {
        get { objc_getAssociatedObject(self, &chrisLoaderKey) as? StreamLoader }
        set { objc_setAssociatedObject(self, &chrisLoaderKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/* ============================================================
   边下边播（AVAssetResourceLoader）

   背景：AVPlayer 走它自己那套网络栈，**不认我们的自签证书**
   （NSAllowsArbitraryLoads 也救不了它）—— 所以「AVPlayer(url: 远程)」一直黑屏。
   以前的办法是先用 App 的会话把**整段**下到本地再播，代价是「要等下完才出画面」。

   这里换一条路：把地址换成自定义 scheme（chrisplay://…），
   AVFoundation 的每个请求（播放列表 / 分片 / mp4 的字节范围）都回到我们手里，
   我们再用 **App 自己的 URLSession**（认自签证书）去取，取到一段就喂一段 ——
   于是「够一小段就起播」，后面边看边下，不用等整段。

   · HLS：主播放列表里的相对地址会自动解析成同一个自定义 scheme，
     所以分片也全部走这里，不会再各自去撞证书。
   · MP4：AVPlayer 自己会发 Range 请求，我们原样转发（服务器支持 206）。
   ============================================================ */

/// 所有流式加载共用一个 URLSession（省线程、省内存），
/// 回调按 taskId 转交给对应的 StreamLoader。
final class StreamHub: NSObject, URLSessionDataDelegate, URLSessionDelegate {
    static let shared = StreamHub()

    private var session: URLSession!
    private let lock = NSLock()
    private var owners: [Int: StreamLoader] = [:]

    private override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 900
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func start(_ r: URLRequest) -> URLSessionDataTask {
        session.dataTask(with: r)
    }

    func bind(_ task: URLSessionDataTask, _ owner: StreamLoader) {
        lock.lock(); owners[task.taskIdentifier] = owner; lock.unlock()
    }

    private func owner(_ task: URLSessionTask) -> StreamLoader? {
        lock.lock(); defer { lock.unlock() }
        return owners[task.taskIdentifier]
    }

    private func unbind(_ task: URLSessionTask) -> StreamLoader? {
        lock.lock(); defer { lock.unlock() }
        return owners.removeValue(forKey: task.taskIdentifier)
    }

    /* 自签证书：无条件接受（和 App 其它请求一个口径） */
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        owner(dataTask)?.received(response: response, task: dataTask)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner(dataTask)?.received(data: data, task: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        unbind(task)?.completed(task: task, error: error)
    }
}

/// 把一个视频地址喂给 AVPlayer：AVFoundation 的加载请求 → 我们的会话 → 边取边喂。
final class StreamLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "chrisplay"

    let queue = DispatchQueue(label: "chris.stream.loader")
    private let token: String
    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]

    private final class Entry {
        let req: AVAssetResourceLoadingRequest
        var task: URLSessionDataTask?
        var done = false
        init(req: AVAssetResourceLoadingRequest) { self.req = req }
    }

    init(token: String) {
        self.token = token
        super.init()
    }

    /* ---------------- 地址换装 ---------------- */

    static func fakeURL(_ u: URL) -> URL? {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = scheme
        return c.url
    }

    /// 把 chrisplay://… 换回真正的 https://…
    static func realURL(_ u: URL) -> URL? {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "https"
        return c.url
    }

    /* ---------------- AVAssetResourceLoaderDelegate ---------------- */

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let fake = loadingRequest.request.url, let real = StreamLoader.realURL(fake) else { return false }
        var r = URLRequest(url: real)
        r.httpMethod = "GET"
        if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        /* 字节范围：AVPlayer 要哪一段就给哪一段（mp4 靠它边下边播） */
        if let dr = loadingRequest.dataRequest {
            if dr.requestsAllDataToEndOfResource {
                r.setValue("bytes=\(dr.requestedOffset)-", forHTTPHeaderField: "Range")
            } else if dr.requestedLength > 0 {
                let end = dr.requestedOffset + Int64(dr.requestedLength) - 1
                r.setValue("bytes=\(dr.requestedOffset)-\(end)", forHTTPHeaderField: "Range")
            }
        }
        let e = Entry(req: loadingRequest)
        let task = StreamHub.shared.start(r)
        e.task = task
        lock.lock(); entries[task.taskIdentifier] = e; lock.unlock()
        StreamHub.shared.bind(task, self)
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        var victim: Entry?
        lock.lock()
        if let k = entries.first(where: { $0.value.req === loadingRequest })?.key {
            victim = entries.removeValue(forKey: k)
        }
        lock.unlock()
        victim?.task?.cancel()
    }

    /// 播放器被丢掉了：把还在下着的请求全掐掉。
    /// 不掐的话那些「从 0 一直下到结尾」的长请求会一直占着连接，
    /// 后面新建的播放器拿不到连接，表现就是**一直在转圈、就是不出画面**。
    func cancelAll() {
        lock.lock()
        let tasks = entries.values.compactMap { $0.task }
        for e in entries.values { e.done = true }
        entries.removeAll()
        lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    /* ---------------- 会话回调 ---------------- */

    fileprivate func received(response: URLResponse, task: URLSessionDataTask) {
        lock.lock()
        let e = entries[task.taskIdentifier]
        lock.unlock()
        guard let e = e, !e.done, !e.req.isCancelled else { return }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code >= 400 {
            finish(e, error: NSError(domain: "chris.stream", code: code,
                                     userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"]))
            return
        }
        if let ci = e.req.contentInformationRequest {
            let mime = response.mimeType ?? ""
            if !mime.isEmpty { ci.contentType = mime }
            /* 播放列表（m3u8）不能报「支持字节范围」—— 那会让 AVPlayer 按普通文件去要一段 */
            let isPlaylist = mime.contains("mpegurl") || (e.req.request.url?.pathExtension == "m3u8")
            ci.isByteRangeAccessSupported = !isPlaylist
                && (code == 206 || ((http?.value(forHTTPHeaderField: "Accept-Ranges") ?? "").contains("bytes")))
            ci.contentLength = StreamLoader.totalLength(http: http, response: response)
        }
        /* 只要「内容信息」的那种请求（AVPlayer 探测类型/长度）：给完就结 */
        if e.req.dataRequest == nil { finish(e, error: nil) }
    }

    fileprivate func received(data: Data, task: URLSessionDataTask) {
        lock.lock()
        let e = entries[task.taskIdentifier]
        lock.unlock()
        guard let e = e, !e.done, !e.req.isCancelled else { return }
        e.req.dataRequest?.respond(with: data)
    }

    fileprivate func completed(task: URLSessionTask, error: Error?) {
        lock.lock()
        let e = entries.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let e = e, !e.done else { return }
        if e.req.isCancelled { e.done = true; return }
        finish(e, error: error)
    }

    private func finish(_ e: Entry, error: Error?) {
        lock.lock()
        let wasDone = e.done
        e.done = true
        entries.removeValue(forKey: e.task?.taskIdentifier ?? -1)
        lock.unlock()
        guard !wasDone else { return }
        if let err = error { e.req.finishLoading(with: err) } else { e.req.finishLoading() }
    }

    /// 总长度：206 的 Content-Range 里那个「/总数」才是整段长度（写成这一段会被当成小文件）
    private static func totalLength(http: HTTPURLResponse?, response: URLResponse) -> Int64 {
        if let cr = http?.value(forHTTPHeaderField: "Content-Range"),
           let tail = cr.split(separator: "/").last, let n = Int64(tail) {
            return n
        }
        if response.expectedContentLength > 0 { return response.expectedContentLength }
        return -1
    }
}

/// 对外的入口：给一个真实地址，还一个「边下边播」的播放器/条目。
enum StreamPlay {
    /// 加载器不能丢：AVFoundation 只**弱引用**资源加载的 delegate。
    /// 这里留一份强引用（加载器本身很小，里面的请求字典用完就清空）。
    private static var keepAlive: [StreamLoader] = []
    private static let keepLock = NSLock()

    static func makeAsset(_ url: URL) -> AVURLAsset? {
        guard let fake = StreamLoader.fakeURL(url) else { return nil }
        let loader = StreamLoader(token: API.shared.token)
        let asset = AVURLAsset(url: fake)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        keep(loader)
        return asset
    }

    /// 给一个「边下边播」的 AVPlayerItem：加载器挂在 item 上（item 活着它就活着），
    /// item 被丢掉时我们还能顺着它把没下完的请求掐掉。
    static func item(_ url: URL) -> AVPlayerItem? {
        guard let fake = StreamLoader.fakeURL(url) else { return nil }
        let loader = StreamLoader(token: API.shared.token)
        let asset = AVURLAsset(url: fake)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        keep(loader)
        let it = AVPlayerItem(asset: asset)
        it.chrisLoader = loader
        return it
    }

    /// 播放器不播了/被丢掉了：把这个 item 上还没下完的请求掐掉
    static func cancel(_ item: AVPlayerItem?) {
        item?.chrisLoader?.cancelAll()
    }

    static func player(_ url: URL) -> AVPlayer? {
        guard let it = item(url) else { return nil }
        let p = AVPlayer(playerItem: it)
        p.actionAtItemEnd = .none
        /* 有数据就起播（不攒够一大段），弱网下才不会一直转圈 */
        p.automaticallyWaitsToMinimizeStalling = false
        p.currentItem?.preferredForwardBufferDuration = 1.5
        return p
    }

    /// 兜底里的兜底：**整段下到本地再播**（慢，但最稳 —— B877 验证过的老路）。
    /// 本地留底优先；成功返回可以直接丢给 AVPlayer 的文件地址。
    static func download(_ url: URL, preferLocal: Bool = true) async -> URL? {
        if preferLocal, let local = LocalStore.localURL(url.path),
           FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        guard url.scheme == "http" || url.scheme == "https" else { return url }
        /* 整段下载走**流式落盘**（不吃内存）+ 给足超时：
           以前用 assetData 只有 15 秒超时，几 MB 的视频经常下不完就被判失败。 */
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        req.setValue(AppInfo.build, forHTTPHeaderField: "X-App-Build")
        if !API.shared.token.isEmpty { req.setValue("Bearer \(API.shared.token)", forHTTPHeaderField: "Authorization") }
        guard let (tmp, resp) = try? await API.shared.session.download(for: req) else { return nil }
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 { return nil }
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("chris-dl-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.moveItem(at: tmp, to: dst)) != nil else { return nil }
        if let d = try? Data(contentsOf: dst) {
            LocalStore.keep(url.path, data: d)     // 下过一次就留底，下次秒开
        }
        return dst
    }

    private static func keep(_ l: StreamLoader) {
        keepLock.lock()
        keepAlive.append(l)
        /* 不做上限：宁可能多留几个空壳，也不能让还在用的加载器被回收掉 */
        keepLock.unlock()
    }
}
