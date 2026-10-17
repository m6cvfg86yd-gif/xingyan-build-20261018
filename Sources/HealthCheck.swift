import SwiftUI
import UIKit
import Darwin

/* ============================================================
   故障修复与体检（照微信「帮助与反馈 → 小扳手 → 故障修复」那套做的）

   微信那一页是一列检查项，每项点一下自己检测、能修的当场修。这里也一样：
     网络与线路 / 服务器接口 / 实时长连接 / 消息推送 / 会话列表与通讯录 /
     本机聊天记录 / 朋友圈 / 卡包与小店 / 小星档位 / 账号与登录 /
     存储与内存 / 崩溃与日志

   每一项：**先检测**（绿勾 / 红叉 + 一句话说明），能修的右边有一颗「修复」按钮
   （真的动手：重拉数据、清离线缓存、重连长连接、清图片视频缓存、上传日志）。
   顶上两颗： 「全部检测」 和 「上传日志」（日志 + 打点 + 崩溃 + 体检结果一起汇入服务器）。

   入口：我 → 设置 → 更多 → 故障修复；诊断工具页顶上也有一个入口。
   ============================================================ */

struct HealthCheckView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var realtime = Realtime.shared

    struct Row: Identifiable {
        let id: String
        let title: String
        let sub: String
        var state: Int = 0          // 0 未检测 · 1 正常 · 2 有问题 · 3 检测中
        var detail: String = ""
        var fixTitle: String = ""
    }

    @State private var rows: [Row] = [
        Row(id: "net", title: "网络与线路", sub: "能不能连上服务器、走的是哪条线路"),
        Row(id: "api", title: "服务器接口", sub: "会话/通讯录/朋友圈/卡包/小店/小星 逐条打通"),
        Row(id: "rt", title: "实时长连接", sub: "别人发消息能不能立刻收到", fixTitle: "重连"),
        Row(id: "push", title: "消息推送", sub: "息屏时能不能收到通知", fixTitle: "重新登记"),
        Row(id: "chats", title: "会话与通讯录", sub: "本机列表和服务器对不对得上", fixTitle: "重新同步"),
        Row(id: "msgs", title: "本机聊天记录", sub: "本机留底的聊天记录 / 媒体占用"),
        Row(id: "moments", title: "朋友圈", sub: "缓存能铺出来、服务器能拉回来", fixTitle: "重拉"),
        Row(id: "cards", title: "卡包与小店", sub: "卡券和商品拉得到吗", fixTitle: "清缓存重拉"),
        Row(id: "eyes", title: "小星档位", sub: "顶栏那颗眼睛现在的档位", fixTitle: ""),
        Row(id: "account", title: "账号与登录", sub: "登录令牌 / 设备标识 / 端类型"),
        Row(id: "store", title: "存储与内存", sub: "内存占用、本机缓存大小", fixTitle: "清媒体缓存"),
        Row(id: "crash", title: "崩溃与日志", sub: "上次崩溃、日志上报通道", fixTitle: "上传日志")
    ]
    @State private var running = false
    @State private var busyFix = ""
    @State private var uploading = false
    @State private var result = ""

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: Tr("故障修复"), back: { dismiss() }) {
                Button { Task { await runAll() } } label: {
                    Text(running ? Tr("检测中…") : Tr("全部检测"))
                        .font(pf(14.5))
                        .foregroundColor(running ? C.subLabel : C.green)
                        .padding(.horizontal, 12).frame(height: 32)
                }
                .buttonStyle(.plain)
                .disabled(running)
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    Text(Tr("照微信「故障修复」那套：每项先检测、能修的当场修。修的都是本机缓存和连接，不会动服务器上的数据，也不会删聊天记录。"))
                        .font(pf(12.5)).foregroundColor(C.subLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 8)

                    GroupCard {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                            if i > 0 { HairLine(inset: 16) }
                            rowView(r)
                        }
                    }
                    .padding(.top, 2)

                    Button { Task { await uploadLog() } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "paperplane.fill").font(.system(size: 15))
                            Text(uploading ? Tr("正在上传…") : Tr("上传日志（含崩溃）"))
                                .font(pf(16, .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(C.green))
                    }
                    .buttonStyle(.plain)
                    .disabled(uploading || running)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                    if !result.isEmpty {
                        Text(result).font(pf(12.5)).foregroundColor(C.subLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.top, 4)
                    }
                    Spacer().frame(height: 30)
                }
            }
            .background(C.pageBg)
        }
        .background(C.pageBg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .swipeBack { dismiss() }
        .hidesTabBar()
        .task { await runAll() }
    }

    /* ---------------------------------------------------------- 一行 */

    private func rowView(_ r: Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                stateIcon(r.state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Tr(r.title)).font(pf(16)).foregroundColor(C.label)
                    Text(Tr(r.sub)).font(pf(12)).foregroundColor(C.subLabel).lineLimit(2)
                }
                Spacer(minLength: 6)
                if !r.fixTitle.isEmpty {
                    Button { Task { await fix(r.id) } } label: {
                        Text(busyFix == r.id ? Tr("修复中…") : Tr(r.fixTitle))
                            .font(pf(13.5))
                            .foregroundColor(busyFix == r.id ? C.subLabel : C.green)
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(C.fieldBg))
                    }
                    .buttonStyle(.plain)
                    .disabled(running || !busyFix.isEmpty)
                }
                Button { Task { await check(r.id) } } label: {
                    Text(Tr("检测")).font(pf(13)).foregroundColor(C.green)
                }
                .buttonStyle(.plain)
                .disabled(running)
            }
            if !r.detail.isEmpty {
                Text(r.detail)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(r.state == 2 ? C.red : C.subLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func stateIcon(_ s: Int) -> some View {
        Group {
            if s == 3 {
                ProgressView().scaleEffect(0.7)
            } else if s == 1 {
                Image(systemName: "checkmark.circle.fill").foregroundColor(C.green)
            } else if s == 2 {
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(C.red)
            } else {
                Image(systemName: "circle").foregroundColor(C.subLabel)
            }
        }
        .font(.system(size: 17))
        .frame(width: 18, height: 18)
    }

    /* ---------------------------------------------------------- 检测 */

    private func runAll() async {
        if running { return }
        running = true
        for r in rows { await check(r.id) }
        running = false
        let bad = rows.filter { $0.state == 2 }.count
        result = bad == 0 ? Tr("全部通过 ✅") : (Tr("有 ") + String(bad) + Tr(" 项有问题，看上面红字"))
        /* 体检结果也留一条打点（上报日志时会带上） */
        AppLog.info("体检完成：正常 " + String(rows.filter { $0.state == 1 }.count) + " 项 / 异常 " + String(bad) + " 项")
    }

    private func set(_ id: String, _ state: Int, _ detail: String) {
        if let i = rows.firstIndex(where: { $0.id == id }) {
            rows[i].state = state
            rows[i].detail = detail
        }
    }

    private func check(_ id: String) async {
        set(id, 3, "")
        switch id {
        case "net":     await checkNet()
        case "api":     await checkAPI()
        case "rt":      await checkRealtime()
        case "push":    await checkPush()
        case "chats":   await checkChats()
        case "msgs":    await checkMsgs()
        case "moments": await checkMoments()
        case "cards":   await checkCards()
        case "eyes":    await checkEyes()
        case "account": await checkAccount()
        case "store":   await checkStore()
        case "crash":   await checkCrash()
        default:        set(id, 0, "")
        }
    }

    private func checkNet() async {
        let r = await API.shared.healthProbe("/api/health")
        var lines: [String] = []
        lines.append("当前线路 " + API.shared.server + " → " + r.note)
        lines.append("候选线路 " + String(API.shared.diagCandidates.count) + " 条" + (API.shared.offline ? "（正标记离线，会自动换线路）" : ""))
        set("net", r.code == 200 ? 1 : 2, lines.joined(separator: "\n"))
    }

    /// 关键接口逐条打通：哪条 404 就说明这条线路的服务器太旧（卡包为空就是这种）
    private func checkAPI() async {
        let paths = ["/api/session", "/api/me", "/api/me-page", "/api/chats", "/api/contacts",
                     "/api/moments", "/api/cards", "/api/shop", "/api/me/eyes", "/api/service",
                     "/api/miniapps", "/api/ui"]
        var bad = 0
        var lines: [String] = []
        for p in paths {
            let r = await API.shared.healthProbe(p)
            if r.code != 200 { bad += 1 }
            lines.append((r.code == 200 ? "✓ " : "✗ ") + p.replacingOccurrences(of: "/api/", with: "") + "  " + r.note)
        }
        set("api", bad == 0 ? 1 : 2, lines.joined(separator: "\n"))
        if bad > 0 { AppLog.error("体检/接口", "有 " + String(bad) + " 个接口没通（" + API.shared.server + "）") }
    }

    private func checkRealtime() async {
        let ok = realtime.connected
        var lines = [ok ? "长连接正常" : "长连接断了", "服务器 " + API.shared.server]
        if !ok { lines.append("点右边「重连」，或等一下自动重连（最多 15 秒一次）") }
        set("rt", ok ? 1 : 2, lines.joined(separator: "\n"))
    }

    private func checkPush() async {
        let p = PushCenter.shared
        var lines: [String] = []
        lines.append("通知权限 " + (p.authorized ? "已允许" : "没允许（去 iOS 设置里开）"))
        lines.append("推送令牌 " + (p.token.isEmpty ? "还没拿到" : String(p.token.prefix(10)) + "…"))
        if !p.registeredAt.isEmpty { lines.append("登记时间 " + p.registeredAt) }
        set("push", (p.authorized && !p.token.isEmpty) ? 1 : 2, lines.joined(separator: "\n"))
    }

    private func checkChats() async {
        var lines: [String] = []
        lines.append("本机会话 " + String(app.chats.count) + " 个 · 好友 " + String(app.contacts.count) + " 位")
        let r = await API.shared.healthProbe("/api/chats")
        lines.append("服务器会话 → " + r.note)
        let ok = r.code == 200
        set("chats", ok ? 1 : 2, lines.joined(separator: "\n"))
    }

    private func checkMsgs() async {
        var lines: [String] = []
        let usage = LocalStore.usage()
        for (k, v) in usage {
            lines.append(labelOf(k) + " " + LocalStore.text(v))
        }
        let c = LocalStore.cachedChat(app.chats.first?.id ?? "")
        if !c.isEmpty { lines.append("抽查一个会话：本机留底 " + String(c.count) + " 条") }
        set("msgs", 1, lines.joined(separator: "\n"))
    }

    private func checkMoments() async {
        var lines: [String] = []
        let cached = LocalStore.cachedMoments().count
        lines.append("本机朋友圈缓存 " + String(cached) + " 条")
        let r = await API.shared.healthProbe("/api/moments")
        lines.append("服务器 → " + r.note)
        set("moments", r.code == 200 ? 1 : 2, lines.joined(separator: "\n"))
    }

    private func checkCards() async {
        var lines: [String] = []
        let cards = await API.shared.healthProbe("/api/cards")
        lines.append("卡包 → " + cards.note)
        let shop = await API.shared.healthProbe("/api/shop")
        lines.append("小店 → " + shop.note)
        let ok = cards.code == 200 && shop.code == 200
        set("cards", ok ? 1 : 2, lines.joined(separator: "\n"))
        if !ok { AppLog.error("体检/卡包", "卡包或小店接口异常（" + API.shared.server + "）") }
    }

    private func checkEyes() async {
        let e = EyesStore.shared
        if !e.loaded { await e.refresh() }
        let name: String
        switch e.tier {
        case "off":    name = "关闭小星（顶栏不画）"
        case "static": name = "静态小星（画，但不动）"
        default:       name = "开启小星（会动）" + (e.paid ? "，已付费" : "，还没付费")
        }
        var lines = [name, "价格 ¥" + moneyFmt(e.price) + " · 零钱 ¥" + moneyFmt(e.balance)]
        let r = await API.shared.healthProbe("/api/me/eyes")
        lines.append("接口 → " + r.note)
        set("eyes", r.code == 200 ? 1 : 2, lines.joined(separator: "\n"))
    }

    private func checkAccount() async {
        var lines: [String] = []
        let me = app.me
        lines.append("账号 " + ((me?.username ?? "").isEmpty ? "（还没登录）" : (me?.username ?? "")))
        lines.append("端类型 " + AppInfo.deviceKind + " · 设备 " + String(AppInfo.deviceId.prefix(12)) + "…")
        let r = await API.shared.healthProbe("/api/session")
        lines.append("会话 → " + r.note)
        set("account", r.code == 200 ? 1 : 2, lines.joined(separator: "\n"))
    }

    private func checkStore() async {
        var lines: [String] = []
        lines.append("内存占用 " + memText())
        lines.append("本机留底合计 " + LocalStore.text(LocalStore.totalUsage()))
        set("store", 1, lines.joined(separator: "\n"))
    }

    private func checkCrash() async {
        var lines: [String] = []
        let c = CrashCatcher.savedCrash()
        lines.append(c.isEmpty ? "这台机器上没有崩溃记录 ✅" : ("上次崩溃：\n" + String(c.prefix(400))))
        lines.append(AppInfo.build)
        set("crash", c.isEmpty ? 1 : 2, lines.joined(separator: "\n"))
    }

    private func labelOf(_ k: String) -> String {
        switch k {
        case "video": return "视频"
        case "image": return "图片"
        case "voice": return "语音"
        case "file":  return "文件"
        case "chat":  return "聊天记录留底"
        default:      return k
        }
    }

    private func memText() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return "读不到" }
        let used = Double(info.phys_footprint) / 1_048_576.0
        return String(format: "%.0f MB（还能用 %.0f MB）", used, Double(info.limit_bytes_remaining) / 1_048_576.0)
    }

    /* ---------------------------------------------------------- 修复（真动手） */

    private func fix(_ id: String) async {
        busyFix = id
        let what = rows.first(where: { $0.id == id })?.title ?? id
        switch id {
        case "rt":
            Realtime.shared.stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
            Realtime.shared.start()
        case "push":
            PushCenter.shared.start()
            PushCenter.shared.uploadIfPossible()
        case "chats":
            await app.loadChats()
            await app.loadContacts()
        case "moments":
            await app.loadMoments()
        case "cards":
            API.clearOfflineCache()
            _ = try? await API.shared.shopData()
            _ = await API.shared.walletCardsDiag()
            app.me = try? await API.shared.me()
        case "store":
            LocalStore.clear("image")
            LocalStore.clear("video")
        case "crash":
            await uploadLog()
        default:
            break
        }
        AppLog.info("故障修复：" + what)
        result = Tr("已修复：") + Tr(what)
        busyFix = ""
        await check(id)
    }

    /* ---------------------------------------------------------- 上传日志（含崩溃） */

    private func uploadLog() async {
        if uploading { return }
        uploading = true
        var text = "=== App 日志（" + AppInfo.build + "） ===\n"
        text += "时间 " + ISO8601DateFormatter().string(from: Date()) + "\n"
        text += "账号 " + (app.me?.username ?? "-") + " · " + AppInfo.deviceKind + "\n"
        text += "线路 " + API.shared.server + " · 候选 " + String(API.shared.diagCandidates.count) + " 条\n"
        text += "长连接 " + (realtime.connected ? "正常" : "断开") + "\n"
        text += "内存 " + memText() + "\n"
        text += "\n--- 体检结果 ---\n"
        for r in rows {
            let s = r.state == 1 ? "正常" : (r.state == 2 ? "异常" : "未测")
            text += "[" + s + "] " + r.title + "：" + r.detail.replacingOccurrences(of: "\n", with: " / ") + "\n"
        }
        let crash = CrashCatcher.savedCrash()
        if !crash.isEmpty { text += "\n--- 上次崩溃 ---\n" + String(crash.prefix(2000)) + "\n" }
        let points = DiagLog.shared.lines
        if !points.isEmpty { text += "\n--- 打点（最近 20 条）---\n" + points.joined(separator: "\n") + "\n" }
        let scroll = ChatScrollDiag.shared.lines
        if !scroll.isEmpty { text += "\n--- 聊天页滚动诊断 ---\n" + scroll.joined(separator: "\n") + "\n" }

        /* 一条最多按 3500 字切段发（和诊断工具那条通道一样），服务器按 kind 归类 */
        let n = max(1, Int(ceil(Double(text.count) / 3500.0)))
        for i in 0..<n {
            let s = text.index(text.startIndex, offsetBy: min(i * 3500, text.count))
            let e = text.index(s, offsetBy: min(3500, text.distance(from: s, to: text.endIndex)))
            let seg = String(text[s..<e])
            CrashCatcher.note("日志上传", "【第 " + String(i + 1) + "/" + String(n) + " 段】\n" + seg)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        uploading = false
        result = Tr("已上传 ") + String(n) + Tr(" 段日志（含崩溃与打点），在「管理 → App 日志」里能看")
        AppLog.info("上传日志：" + String(n) + " 段")
    }
}
