import SwiftUI
import UIKit
import Darwin

/* ============================================================
   设置 → 诊断工具

   把「查问题」要用的东西全放一页，用户点一下就能上报给我：
     · 版本 / 机型系统 / 设备标识 / 账号 / 服务器地址
     · 内存占用 + 本机缓存占用
     · 网络检测（连不连得上、延迟多少毫秒）
     · 上次崩溃（CrashCatcher 落盘的那份，被杀掉也在）
     · 最近 14 条滚动诊断（聊天页那套打点）
     · 「上报」= 把这些打包成一条发给服务器（和崩溃上报同一个通道，
       在后台 data/client-errors.jsonl 里就能看到）
   ============================================================ */

struct DiagView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var scrollDiag = ChatScrollDiag.shared
    /// 通用打点（卡包 / 小店 / 被顶下线这些，见下面的 DiagLog）
    @ObservedObject private var diagLog = DiagLog.shared

    @State private var msg = ""
    @State private var busy = false
    @State private var net = "点下面「网络检测」"
    @State private var crash = ""
    @State private var disk = "…"
    @State private var mem = "…"
    @State private var copied = false
    /// 「故障修复与体检」那一页（整页打开）
    @State private var showHealth = false

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("诊断工具"), back: { dismiss() }) {
                Button { Task { await upload() } } label: {
                    Text(busy ? Tr("上报中…") : Tr("上报"))
                        .font(pf(15, .medium))
                        .foregroundColor(busy ? C.subLabel : C.green)
                        .padding(.horizontal, 14).frame(height: 32)
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    head(Tr("这台机器 / 这个版本"))
                    rows([
                        (Tr("App 版本"), AppInfo.build),
                        (Tr("机型 · 系统"), deviceText),
                        (Tr("设备标识"), String(AppInfo.deviceId.prefix(18)) + "…"),
                        (Tr("账号"), accountText),
                        (Tr("服务器"), API.shared.base),
                        (Tr("内存占用"), mem),
                        (Tr("本机缓存"), disk),
                        (Tr("网络"), net)
                    ])

                    head(Tr("动手查"))
                    VStack(spacing: 0) {
                        action(Tr("网络检测"), "wifi") { Task { await netCheck() } }
                        HairLine(inset: 16)
                        /* 微信那套「故障修复」：一列检查项 + 能修的当场修 */
                        action(Tr("故障修复与体检"), "wrench.and.screwdriver") { showHealth = true }
                        HairLine(inset: 16)
                        action(Tr("刷新内存 / 缓存"), "arrow.clockwise") { Task { await refresh() } }
                        HairLine(inset: 16)
                        action(Tr("一键上报给开发者"), "paperplane") { Task { await upload() } }
                        HairLine(inset: 16)
                        action(copied ? Tr("已复制") : Tr("复制全部信息"), "doc.on.doc") { copyAll() }
                    }
                    .background(C.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 12)

                    if !msg.isEmpty {
                        Text(msg).font(pf(12.5)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18).padding(.top, 10)
                    }

                    head(Tr("上次崩溃（本机存的）"))
                    box(crash.isEmpty ? Tr("这台机器上还没有崩溃记录") : crash)

                    head(Tr("最近 14 条滚动诊断"))
                    box(scrollDiag.lines.isEmpty ? Tr("（还没有记录）") : scrollDiag.lines.joined(separator: "\n"))

                    /* 通用打点：卡包「空的」、小店下单失败、被顶下线这类问题都记在这儿，
                       用户截图 / 一键上报就能一眼看出卡在哪一步。 */
                    head(Tr("最近 20 条打点（卡包 / 小店 / 登录）"))
                    box(diagLog.lines.isEmpty ? Tr("（还没有记录）") : diagLog.lines.joined(separator: "\n"))

                    Spacer().frame(height: 30)
                }
                .padding(.top, 10)
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea(edges: .top))
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .fullScreenCover(isPresented: $showHealth) {
            HealthCheckView().environmentObject(app)
        }
        .task { await refresh() }
    }

    /* ---------------------------------------------------------- 小零件 */

    private var deviceText: String {
        let d = UIDevice.current
        return d.model + " · iOS " + d.systemVersion
    }

    private var accountText: String {
        guard let me = app.me else { return "没登录" }
        let u = (me.username ?? "").isEmpty ? "—" : (me.username ?? "")
        return u + " · " + me.id
    }

    private func head(_ t: String) -> some View {
        HStack {
            Text(t).font(pf(13)).foregroundColor(C.subLabel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }

    private func rows(_ list: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.offset) { i, r in
                if i > 0 { HairLine(inset: 16) }
                HStack(alignment: .top, spacing: 10) {
                    Text(r.0).font(pf(15)).foregroundColor(C.label)
                        .frame(width: 88, alignment: .leading)
                    Text(r.1).font(pf(13.5)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 16).padding(.vertical, 11)
            }
        }
        .background(C.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func action(_ t: String, _ icon: String, _ tap: @escaping () -> Void) -> some View {
        Button { tap() } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16)).foregroundColor(C.green)
                    .frame(width: 26)
                Text(t).font(pf(15.5)).foregroundColor(C.label)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(C.subLabel)
            }
            .padding(.horizontal, 16).frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func box(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundColor(C.label.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .padding(12)
            .background(C.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 12)
    }

    /* ---------------------------------------------------------- 干活 */

    private func refresh() async {
        mem = memoryText()
        crash = CrashCatcher.savedCrash()
        disk = await Task.detached(priority: .utility) { Self.cacheText() }.value
    }

    private func netCheck() async {
        net = Tr("检测中…")
        let t0 = Date()
        var ok = false
        /* ⚠ 这里以前打的是 /api/ping —— 服务器上没有这条路由，永远回 401，
           于是网络明明是通的也报「不通」。改成公开的 /api/health（200 才算通）。 */
        if let url = URL(string: API.shared.base + "/api/health") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.cachePolicy = .reloadIgnoringLocalCacheData
            /* 必须用 App 自己的会话（TrustAllDelegate）：自签证书用 URLSession.shared
               会被 TLS 拦住，一直是「不通」。 */
            if let (_, resp) = try? await API.shared.session.data(for: req),
               let h = resp as? HTTPURLResponse, h.statusCode == 200 { ok = true }
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        net = (ok ? Tr("通") : Tr("不通")) + " · \(ms)ms"
    }

    /// 把这一页的东西打包发上去（走崩溃上报那条通道）
    private func upload() async {
        busy = true
        await refresh()
        let all = fullText()
        /* 一条最多 4000 字（通道按这个切），长就分段发 */
        let n = max(1, Int(ceil(Double(all.count) / 3500.0)))
        for i in 0..<n {
            let s = all.index(all.startIndex, offsetBy: min(i * 3500, all.count))
            let e = all.index(s, offsetBy: min(3500, all.distance(from: s, to: all.endIndex)))
            CrashCatcher.note("诊断", "【第 \(i + 1)/\(n) 段】\n" + String(all[s..<e]))
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        msg = Tr("已上报（共 ") + "\(n)" + Tr(" 段）")
        busy = false
    }

    private func copyAll() {
        UIPasteboard.general.string = fullText()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func fullText() -> String {
        var s = "=== 星言诊断报告 ===\n"
        s += "时间：" + ISO8601DateFormatter().string(from: Date()) + "\n"
        s += "App：" + AppInfo.build + "\n"
        s += "机型：" + deviceText + "\n"
        s += "设备标识：" + AppInfo.deviceId + "\n"
        s += "账号：" + accountText + "\n"
        s += "服务器：" + API.shared.base + "\n"
        s += "内存：" + mem + "\n"
        s += "缓存：" + disk + "\n"
        s += "网络：" + net + "\n"
        s += "会话数：\(app.chats.count) · 好友数：\(app.contacts.count)\n"
        s += "\n=== 上次崩溃 ===\n" + (crash.isEmpty ? "（无）" : crash) + "\n"
        s += "\n=== 最近滚动诊断 ===\n" + (scrollDiag.lines.isEmpty ? "（无）" : scrollDiag.lines.joined(separator: "\n")) + "\n"
        s += "\n=== 最近打点（卡包 / 小店 / 登录） ===\n" + (DiagLog.shared.lines.isEmpty ? "（无）" : DiagLog.shared.lines.joined(separator: "\n")) + "\n"
        return s
    }

    /* ---------------------------------------------------------- 系统信息 */

    /// 进程实际占的内存（phys_footprint：系统按这个值决定要不要杀掉 App）
    private func memoryText() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return "读不到" }
        let used = Double(info.phys_footprint) / 1_048_576.0
        let left = Double(info.limit_bytes_remaining) / 1_048_576.0
        return String(format: "%.0f MB（还能用 %.0f MB）", used, left)
    }

    /// 本机缓存（Caches + Documents/Local）占多少
    private static func cacheText() -> String {
        let fm = FileManager.default
        var total: Int64 = 0
        var files = 0
        var dirs: [URL] = []
        if let c = fm.urls(for: .cachesDirectory, in: .userDomainMask).first { dirs.append(c) }
        if let d = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            dirs.append(d.appendingPathComponent("Local", isDirectory: true))
        }
        for dir in dirs {
            guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { continue }
            for case let f as URL in e {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true {
                    total += Int64(v?.fileSize ?? 0)
                    files += 1
                }
            }
        }
        let mb = Double(total) / 1_048_576.0
        return String(format: "%.1f MB · %d 个文件", mb, files)
    }
}

/* ============================================================
   通用打点（卡包「空的」、小店下单失败、被顶下线这类问题都记这儿）

   为什么不用 ChatScrollDiag：那条日志每行都带「离底多少 pt」，是聊天页专用的格式。
   这里就是一行一条、最多留 20 条，带时间；「设置 → 通用 → 更多 → 诊断工具」里能看到，
   一键上报的时候也会一起发上来。
   ============================================================ */
final class DiagLog: ObservableObject {
    static let shared = DiagLog()
    @Published private(set) var lines: [String] = []

    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    func note(_ text: String) {
        let line = fmt.string(from: Date()) + "  " + text
        if Thread.isMainThread { push(line) }
        else { DispatchQueue.main.async { self.push(line) } }
    }

    private func push(_ line: String) {
        var next = lines
        next.insert(line, at: 0)
        if next.count > 20 { next.removeLast(next.count - 20) }
        lines = next
    }
}
