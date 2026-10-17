import SwiftUI
import UIKit
import UserNotifications
import AudioToolbox

/* 新消息通知：按「消息通知」里的设置真响真震
   · on 关掉：什么都不做
   · sound / vibrate：前台用系统音效 + 震动
   · showDetail 关掉：通知只显示「你收到一条新消息」，不带内容
   · 免打扰时段：这段里不响不震
   同时发一条本地通知，App 在后台/锁屏也能看到（不需要 APNs） */
enum LocalNotify {
    static var settings = NotifySettings()

    static func prepare() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        prepareCallCategory()      // 顺手把来电通知上的「接听 / 拒绝」按钮注册上
    }

    /* ---------------- 来电通知（方案 2：App 在外面也能看到、能接）----------------
       WeChat 那种「锁屏直接全屏来电」要 CallKit + VoIP 推送（需要付费开发者账号 + 带 VoIP
       权限的签名），我们先用本地通知这条：App 在后台/锁屏时，来电会弹一条**带铃声、
       不会自动消失**的通知，上面有「接听 / 拒绝」两个按钮，点一下就能接。 */

    static let callCategory = "chris.call"

    static func prepareCallCategory() {
        let answer = UNNotificationAction(identifier: "call.answer", title: "接听", options: [.foreground])
        let reject = UNNotificationAction(identifier: "call.reject", title: "拒绝", options: [.destructive])
        let cat = UNNotificationCategory(identifier: callCategory, actions: [answer, reject],
                                         intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    /// 来电：发一条带铃声的本地通知（锁屏/主屏都能看到）。同一次通话只留一条。
    static func incomingCall(callId: String, peerName: String, video: Bool) {
        let c = UNMutableNotificationContent()
        c.title = video ? "视频通话" : "语音通话"
        c.body = (peerName.isEmpty ? "有人" : peerName) + "邀请你" + (video ? "视频" : "语音") + "通话"
        c.sound = .default
        c.categoryIdentifier = callCategory
        c.userInfo = ["callId": callId, "kind": "call"]
        if #available(iOS 15.0, *) { c.interruptionLevel = .timeSensitive }
        let req = UNNotificationRequest(identifier: "call-" + callId, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// 通话结束 / 被取消：把那条来电通知撤掉，别在锁屏上留残影
    static func clearCall(callId: String) {
        guard !callId.isEmpty else { return }
        let ids = ["call-" + callId]
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    static func refresh() async {
        settings = await API.shared.notifySettings()
    }

    /// 现在是不是在免打扰时段里（22:00—07:00 这种跨天也算）
    static func mutedNow() -> Bool {
        let a = settings.muteStart, b = settings.muteEnd
        guard !a.isEmpty, !b.isEmpty else { return false }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        guard let s = f.date(from: a), let e = f.date(from: b) else { return false }
        let cal = Calendar.current
        let now = cal.dateComponents([.hour, .minute], from: Date())
        let cur = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        let sv = cal.dateComponents([.hour, .minute], from: s)
        let ev = cal.dateComponents([.hour, .minute], from: e)
        let start = (sv.hour ?? 0) * 60 + (sv.minute ?? 0)
        let end = (ev.hour ?? 0) * 60 + (ev.minute ?? 0)
        if start == end { return false }
        return start < end ? (cur >= start && cur < end) : (cur >= start || cur < end)
    }

    /// 收到一条不属于当前会话的新消息
    /// msgId：这条消息的 id —— 通知的 identifier 用它（同一条消息只留一条通知，不会重复堆）
    static func incoming(title: String, body: String, chatId: String = "", msgId: String = "", badge: Int = 0) {
        guard settings.on else { return }
        guard !mutedNow() else { return }
        if settings.sound { AudioServicesPlaySystemSound(1007) }
        if settings.vibrate { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = settings.showDetail ? body : "你收到一条新消息"
        if settings.sound { c.sound = .default }
        /* 桌面图标上的数字（和微信一样：未读数） */
        c.badge = NSNumber(value: max(0, min(999, badge)))
        /* 带上 chatId：点通知直接进那个聊天（和服务器推的 APNs 通知一个规矩） */
        if !chatId.isEmpty { c.userInfo = ["chatId": chatId] }
        /* 同一个会话的通知归到一组（iOS 会把它们叠成一条，和微信一样）；
           identifier **按消息 id** 走 —— 以前是随机 UUID，同一条消息被通知两次就堆两条，
           用户报的「同一条通知反复推送」就是这么来的。 */
        if !chatId.isEmpty { c.threadIdentifier = chatId }
        let id: String
        if !msgId.isEmpty { id = "msg-" + msgId }
        else if !chatId.isEmpty { id = "chat-" + chatId }
        else { id = UUID().uuidString }
        let req = UNNotificationRequest(identifier: id, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /* ---------------- 去重 + 只推「刚发来的」 ----------------
       用户 2026-10-14 报：「同一条通知反复推送」「后面的消息反而不推了，
       就推一条已经发了好些时间的」。前者是随机 identifier 造成的（现在按 msgId），
       这两个方法负责后者：同一个会话里同一条消息只推一次，而且要**两分钟内**的才推
       （通知里再出现几条十分钟前的旧消息，看着就像"通知乱了"）。 */

    private static var lastNotified: [String: String] = [:]
    private static var lastNotifiedLoaded = false

    private static func loadLastNotified() {
        guard !lastNotifiedLoaded else { return }
        lastNotifiedLoaded = true
        if let d = UserDefaults.standard.dictionary(forKey: "chris.lastNotified") as? [String: String] {
            lastNotified = d
        }
    }

    private static func saveLastNotified() {
        UserDefaults.standard.set(lastNotified, forKey: "chris.lastNotified")
    }

    /// 这条要不要推：同一条不重复推、太旧的（>2 分钟）不推
    static func shouldNotify(chatId: String, msgId: String, at: String?) -> Bool {
        loadLastNotified()
        guard !chatId.isEmpty else { return true }
        if !msgId.isEmpty, lastNotified[chatId] == msgId { return false }     // 同一条
        if let d = TimeFmt.date(at), Date().timeIntervalSince(d) > 120 { return false }   // 早就发出来的
        if !msgId.isEmpty { lastNotified[chatId] = msgId; saveLastNotified() }
        return true
    }

    /// 进这个会话：把它已经挂在通知中心/锁屏上的通知撤掉（微信也是这样，看完就没了）
    static func clearChat(_ chatId: String) {
        guard !chatId.isEmpty else { return }
        UNUserNotificationCenter.current().getDeliveredNotifications { list in
            let ids = list.filter { ($0.request.content.userInfo["chatId"] as? String) == chatId }
                .map { $0.request.identifier }
            if !ids.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
        loadLastNotified()
        lastNotified[chatId] = nil
        saveLastNotified()
    }
}
