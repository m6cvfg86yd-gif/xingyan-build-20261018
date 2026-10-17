import Foundation
import os

/* ============================================================
   系统 App 日志 + 崩溃汇入（2026-10-12 加）

   一条日志同时去三个地方，各干各的活：
     ① **iOS 统一日志**（Logger / OSLog，subsystem = bundle id）
        连着电脑用「控制台 Console.app」、或者手机上「设置 → 隐私与安全性 → 分析与改进」
        都能看到；分 app / net / crash 三个 category，方便过滤。
     ② **本机打点** DiagLog（诊断工具页「最近 20 条打点」，一键上报会一起带上去）
     ③ **汇入服务器**：重要错误（按 kind 节流 60 秒）走 CrashCatcher → POST /api/clientlog
        → 服务器 data/client-errors.jsonl；App 管理页「App 日志 / 崩溃（汇入）」里能按
        类型 / 版本 / 账号查，也能看到完整调用栈。

   为什么要节流：断网时每个接口都会失败，不节流的话几秒钟就能把服务器日志刷爆。
   ============================================================ */

enum AppLog {
    private static let appLogger = Logger(subsystem: "com.chris.chatnative", category: "app")
    private static let netLogger = Logger(subsystem: "com.chris.chatnative", category: "net")
    private static let crashLogger = Logger(subsystem: "com.chris.chatnative", category: "crash")

    private static let lock = NSLock()
    private static var lastSent: [String: Date] = [:]

    /// 普通信息：写系统日志 + 本机打点（不发服务器，免得刷屏）
    static func info(_ text: String, net: Bool = false) {
        if net { netLogger.info("\(text, privacy: .public)") }
        else { appLogger.info("\(text, privacy: .public)") }
        DiagLog.shared.note(text)
    }

    /// 错误 / 异常：写系统日志 + 本机打点 + **汇入服务器**（同 kind 60 秒最多一条）
    static func error(_ kind: String, _ text: String) {
        crashLogger.error("[\(kind, privacy: .public)] \(text, privacy: .public)")
        DiagLog.shared.note(kind + "：" + text)
        lock.lock()
        let now = Date()
        let prev = lastSent[kind]
        let allow = (prev == nil) || now.timeIntervalSince(prev!) > 60
        if allow { lastSent[kind] = now }
        lock.unlock()
        guard allow else { return }
        CrashCatcher.note(kind, text)
    }

    /// 崩溃：只写系统日志（真正的崩溃栈由 CrashCatcher 的 signal/exception 回调负责）
    static func crash(_ text: String) {
        crashLogger.fault("\(text, privacy: .public)")
    }
}
