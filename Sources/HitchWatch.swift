import Foundation

/* ============================================================
   卡顿打点：主线程一卡，定时器就会迟到 —— 用「实际间隔 - 预期间隔」量出卡了多久。
   攒够几条（或单次超过 0.5 秒）就上报服务器，日志里能看到「哪一屏、几次、最长多久」。
   这样定位性能问题是看数据，不是猜。
   ============================================================ */

final class HitchWatch {
    static let shared = HitchWatch()

    private var page = ""
    private var timer: Timer?
    private var interval: TimeInterval = 0.5
    private var last = Date()
    private var count = 0
    private var worst: TimeInterval = 0
    private var reportedAt = Date.distantPast

    private init() { }

    func start(_ p: String) {
        page = p
        guard timer == nil else { return }
        last = Date()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let now = Date()
        let gap = now.timeIntervalSince(last) - interval
        last = now
        /* 只有 150ms ~ 3 秒才算「主线程被占住」。
           超过 3 秒的一定是 App 切到后台/锁屏了（Timer 被系统冻住，
           一回到前台就迟到好几秒）—— 那不是卡顿，是误报。
           以前这些误报会被记成「卡顿 7000ms」，把真正的问题埋掉。 */
        if gap > 0.15 && gap < 3.0 {
            count += 1
            worst = max(worst, gap)
        } else if gap >= 3.0 {
            count = 0
            worst = 0
            return
        }
        /* 攒够 3 次、或者单次超过 0.5 秒，就报一次（上报本身也限流，最多 30 秒一次） */
        let shouldReport = (count >= 3 || worst > 0.5) && now.timeIntervalSince(reportedAt) > 30
        guard shouldReport else { return }
        let msg = "卡顿 \(page)：\(count) 次，最长 \(Int(worst * 1000))ms"
        count = 0
        worst = 0
        reportedAt = now
        Task { await API.shared.callDiag(msg) }      // 复用现成的诊断上报通道
    }
}
