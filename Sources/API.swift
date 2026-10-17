import Foundation
import UIKit
import SwiftUI          // 服务页样式里要算颜色（Color）
import AVFoundation     // 视频边下边播要用 AVURLAsset

/* ============================================================ 数据模型 */

struct User: Codable, Identifiable, Hashable {
    var id: String
    /// 脱敏实名（服务端 realNameOf 算好的）：转账页「转账给 **宇」用；
    /// 只有本人和好友的名片才带这个值，陌生人返回空串。
    var realName: String?
    var requestId: String?
    var moodText: String?
    var moodIcon: String?
    var moodColor: String?
    var moodColor2: String?
    /// 状态名（后台配的「摸鱼」这种）和「说点什么」那句自定义文案，是分开的两层
    var moodLabel: String?
    var moodCaption: String?
    /// 状态什么时候过期（毫秒时间戳，0 = 没有状态）
    var moodExpiresAt: Double?
    /// 状态收到的赞（谁赞的）——「朋友的状态」那一页显示 + 判断我赞过没有
    var moodLikes: [String]?
    var moodLikeCount: Int?
    var username: String?
    /// 上一次改「星言号」的时间（服务端存；用来算"一年只能改一次"的剩余时间）
    var usernameUpdatedAt: String?
    /// 兴趣分类：新用户强引导里选择，最多 5 个
    var interests: [String]?
    /// 只有注册时明确标记的新用户才为 true；老账号没有这个字段
    var needsOnboarding: Bool?
    var nickname: String?
    var avatar: String?
    var bio: String?
    var gender: String?
    var region: String?
    var phone: String?
    var status: String?
    var chatBackground: String?
    var birthday: String?
    var momentCover: String?
    /// 拍一拍后缀（微信：我 → 个人资料 → 拍一拍）：别人拍我时念成「拍了拍我的＿＿」
    var patText: String?
    var bot: Bool?
    /// 这个账号有没有「App 内的管理」权限（上新音乐 / 换图标）——
    /// 服务器 users.json 里 ops=true 才会有；别人看不到这个入口
    var ops: Bool?
    var online: Bool?
    var balance: Double?
    /// 我和他的关系：self / friend / incoming / requested / none（名片页按钮按它变）
    var relation: String?
    /// 他发过几条朋友圈（名片上朋友圈那一行有没有）
    var momentCount: Int?
    /// 他的朋友圈可见范围：3d 最近三天 / 6m 最近半年 / all 全部。
    /// 只有「我加了他」的名片（/api/users/{id} 走 memberProfile）才带这个值 ——
    /// 名片上那句「朋友仅展示最近三天的朋友圈」用的就是它。
    var momentsRange: String?
    /// 好友申请里那句验证消息（「新的朋友」里显示）
    var requestMessage: String?
    /// 我给这个人设的备注名（设了以后列表/会话标题都显示它）
    var remark: String?
    /// 他的真实昵称（有备注时用它显示小字）
    var realNickname: String?
    /// 我给他打的标签
    var tags: [String]?
    /// 星标朋友
    var star: Bool?
    /// 我拉黑了他
    var block: Bool?
    /// 我不看他（她）的朋友圈
    var noMoments: Bool?
    /// 好友添加时间 / 来源（我加的 / 他加的我）
    var addedAt: String?
    var source: String?
    /// 我和他共同在几个群里
    var mutualGroups: Int?
    /// 群昵称（微信「设置群昵称」）：只有群成员列表里才带，没设就是空
    var alias: String?
    /// 等级（QQ 那套：活跃天换算出来的级别），0 = 还没开始
    var qqLevel: Int?
    /* 会员：有值就是会员（列表里挂徽章、名字上色用） */
    var memberTier: String?
    var memberShort: String?
    var memberColor: String?
    var memberColor2: String?

    var name: String {
        if let n = nickname, !n.isEmpty { return n }
        if let u = username, !u.isEmpty { return u }
        return "未知用户"
    }
    /// 群里显示的名字：设了群昵称就用群昵称（和微信一样）
    var groupName: String {
        if let a = alias, !a.isEmpty { return a }
        return name
    }
    var avatarPath: String { avatar ?? "" }
}

struct LastMessage: Decodable, Hashable {
    var id: String?
    var senderId: String?
    var senderName: String?
    var kind: String?
    var preview: String?
    var createdAt: String?
    /// 这条 @ 了我（会话列表那一行会带「[有人@我]」）
    var mentionMe: Bool?
}

struct Chat: Decodable, Identifiable, Hashable {
    var id: String
    var type: String?
    var title: String?
    var avatar: String?
    /// 好友的「状态」（微信那种：会话列表头像右下角挂一个 emoji）
    var moodIcon: String?
    var moodText: String?
    var unread: Int?
    var pinned: Bool?
    var botRank: Int?
    /// 单聊对方是哪个机器人账号：ai / housekeeper / qqnews / kefu（不是机器人就是空）
    /// —— 「星联世界」那一页（qqnews）要换成腾讯新闻那种排版，就靠这个认
    var bot: String?
    /// 「星言团队」那条系统通知会话（照微信的「微信团队」做：底下带自助工具 / 联系客服）
    var sysTeam: Bool?
    /// 这条会话对面是公众号的话，给的是那个号的 id（点进去直接开「公众号页面」）
    var oaId: String?
    /// 对面是「订阅号消息」这个汇总号（点进去开公众号列表）
    var oaDigest: Bool?
    /// 单聊对方的等级（QQ 那套）：会话列表昵称旁边挂图标用
    var qqLevel: Int?
    var memberCount: Int?
    /// 会话成员（单聊里用来找「对方是谁」，打语音/视频要用）
    var memberIds: [String]?
    var lastMessage: LastMessage?
    var updatedAt: String?
    /// 消息免打扰（群屏蔽）
    var muted: Bool?
    /// 这个会话开着「阅后即焚」（服务端算好给客户端）：对方看过 8 秒后消息自动消失
    var burn: Bool?
    /// 这个会话是「左滑 → 标为未读」点过的（微信里这种只点一个小红点，
    /// 不给数字；进会话就消掉）。服务端算好给客户端。
    var flagged: Bool?
    /// 群主 id（群聊才有）
    var ownerId: String?
    /// 群公告（群聊才有）
    var announce: String?
    /// 群禁言：全员禁言 / 我有没有被单独禁言
    var muteAll: Bool?
    var meMuted: Bool?
    /* 会员（我们自己那套）：单聊看对方、群聊看群主，列表里挂徽章用 */
    var memberTier: String?
    var memberShort: String?
    var memberColor: String?
    var memberColor2: String?

    var name: String {
        /* 服务端偶尔会回纯空格的标题；以前只判断 isEmpty，空格会原样画出来，
           会话列表就多出一整行“看不见名字”的空白。这里统一收拾干净。 */
        let clean = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "会话" : clean
    }
    var unreadCount: Int { unread ?? 0 }
}

/// 图片消息正文 → 图片地址。
/// 老消息存的是纯路径（/uploads/x.jpg）；这里同时兼容
/// {"url":"...","w":..,"h":..} 这种信封写法，以后换格式也不会把老图读坏。
func imageRefPath(_ content: String) -> String {
    let b = content
    guard b.hasPrefix("{"), let d = b.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let u = o["url"] as? String, !u.isEmpty else { return b }
    return u
}

/// 引用卡片（微信「引用」那条）：引用的原消息 id + 谁说的 + 摘要 + 图片缩略图
struct QuoteRef: Codable, Hashable {
    var id: String?
    var who: String?
    var text: String?
    /// 被引的那条是什么类型（text / image / audio / video …）：图片就给缩略图
    var kind: String?
    /// 图片/视频引用的缩略图地址（没有就留空，只显示文字摘要）
    var thumb: String?

    var refId: String { id ?? "" }
    var sender: String { who ?? "" }
    var summary: String { text ?? "" }
    var thumbPath: String { thumb ?? "" }
}

struct Message: Codable, Identifiable, Hashable {
    var id: String
    var chatId: String?
    var seq: Int?
    var senderId: String?
    var kind: String?
    var content: String?
    var createdAt: String?
    var recalled: Bool?
    /// 结构化引用（微信那种引用卡片）：这条消息引用了哪条、引用的谁、摘要是什么
    var quote: QuoteRef?
    /// 阅后即焚：这条消息带这个小火苗（服务端在这个会话开着时标上的）
    var burn: Bool?
    /// 阅后即焚：这条**什么时候烧**（服务端按「看过 + 20 秒」算好发下来，空 = 还没人看过）
    var burnAt: String?
    var senderName: String?
    var senderAvatar: String?
    /// 通话记录专用的附加信息（服务端写系统消息时带上）
    var call: CallMeta?
    /// 这条消息 @ 了谁（群里才有：存的是被 @ 的 userId 列表）
    var mentions: [String]?
    /// 图片消息的原始像素宽高（发送端带上来的 / 服务端给老消息补的）：
    /// 聊天气泡第一帧就按真实比例把框占好，行高全程不变（骨架落位）
    var imgW: Int?
    var imgH: Int?

    var kindName: String { kind ?? "text" }
    var body: String { content ?? "" }
    var isRecalled: Bool { recalled ?? false }

    /// 图片消息里真正的图片地址。老消息存的是纯路径（/uploads/x.jpg）；
    /// 也兼容 {"url":"...","w":..,"h":..} 这种信封写法。
    var imagePath: String { imageRefPath(body) }

    /// 图片消息的原始像素尺寸（老消息可能没有 → nil）
    var imagePixelSize: CGSize? {
        if let w = imgW, let h = imgH, w > 1, h > 1 { return CGSize(width: CGFloat(w), height: CGFloat(h)) }
        let b = body
        if b.hasPrefix("{"), let d = b.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let w = (o["w"] as? Int) ?? Int((o["w"] as? Double) ?? 0)
            let h = (o["h"] as? Int) ?? Int((o["h"] as? Double) ?? 0)
            if w > 1, h > 1 { return CGSize(width: w, height: h) }
        }
        return nil
    }

    /// 这条消息有没有 @ 这个人
    func mentionsUser(_ userId: String) -> Bool {
        guard !userId.isEmpty, let ids = mentions else { return false }
        return ids.contains(userId)
    }

    /* ---------------- 拍一拍（双击头像）---------------- */
    /// 服务端写的那条「拍一拍」消息里带的客观信息：谁拍了谁、双方当时的显示名
    private var patInfo: [String: Any]? {
        guard kindName == "pat",
              let d = body.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o
    }
    var patFrom: String { (patInfo?["from"] as? String) ?? "" }
    var patTo: String { (patInfo?["to"] as? String) ?? "" }
    var patFromName: String { (patInfo?["fn"] as? String) ?? "" }
    var patToName: String { (patInfo?["tn"] as? String) ?? "" }
    /// 被拍的人设的「拍一拍」后缀（微信：我 → 个人资料 → 拍一拍 → 朋友拍了拍我的＿＿）
    var patTail: String { (patInfo?["tt"] as? String) ?? "" }
    /// 这条「拍了拍」在**我这台手机**上该怎么念（微信的三种说法）
    func patText(myId: String) -> String {
        let fn = patFromName, tn = patToName
        /* 被拍的人设过后缀：微信会念成「拍了拍我的{后缀}」。
           没设就还是原来的「拍了拍了谁」——老消息（没有 tt 字段）自然走这一支。 */
        let tail = patTail.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetTail = tail.isEmpty ? "" : ("的" + tail)      // 别人看他：「张三」拍了拍「李四」的X
        let meTail = tail.isEmpty ? "我" : ("我的" + tail)      // 我是被拍的：「张三」拍了拍我的X
        if !patFrom.isEmpty, patFrom == myId, !tn.isEmpty { return "我拍了拍“" + tn + "”" + targetTail }
        if !patTo.isEmpty, patTo == myId, !fn.isEmpty { return "“" + fn + "”拍了拍" + meTail }
        if !fn.isEmpty, !tn.isEmpty { return "“" + fn + "”拍了拍“" + tn + "”" + targetTail }
        return "拍了拍"
    }

    /// 这行系统消息是不是一条通话记录
    var isCallRecord: Bool {
        if call != nil { return true }
        let t = body
        return t.contains("通话") || t == "已取消" || t == "未接听" || t == "对方无应答"
            || t == "对方已拒绝" || t == "对方忙线中" || t == "对方不在线"
    }
    /// 视频通话（图标画摄像机）
    var isVideoCall: Bool { (call?.media ?? "").contains("video") || body.contains("视频") }
    /// 这条通话记录是谁打出去的（服务端写的；老记录没有，空字符串）
    var callFrom: String { call?.from ?? "" }
    /// 这条通话记录是不是「没接通」那种（微信里这几种是红字）：
    /// 正文里找关键词 + 服务端写的 call.state 一起看 ——
    /// 新记录正文可能只有「通话时长 00:00」而状态写在 call.state 里，
    /// 只看正文会漏，就会显示成普通黑字。
    var isBadCallRecord: Bool {
        guard isCallRecord else { return false }
        let t = body + " " + (call?.state ?? "")
        let words = ["未接听", "已拒绝", "已取消", "无应答", "不在线", "忙线", "未接通",
                     "无人接听", "cancel", "reject", "timeout", "missed", "busy", "offline"]
        return words.contains { t.contains($0) }
    }
    /// 通话记录显示成微信那样：「通话时长 00:12」（老记录的「通话结束 · 时长 0:15」也统一过来）
    var callText: String {
        var t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        for pre in ["视频通话结束", "通话结束"] where t.hasPrefix(pre) {
            if let r = t.range(of: "时长") { t = "通话时长" + String(t[r.upperBound...]) }
            break
        }
        if t.hasPrefix("视频通话时长") { t = "通话时长" + String(t.dropFirst("视频通话时长".count)) }
        if t.hasPrefix("通话时长") {
            let rest = t.dropFirst("通话时长".count).trimmingCharacters(in: .whitespaces)
            let p = rest.split(separator: ":")
            if p.count == 2, let mm = Int(p[0]), let ss = Int(p[1]) {
                t = String(format: "通话时长 %02d:%02d", mm, ss)
            }
        }
        return t
    }
}

/// 通话系统消息的附加信息：媒体类型、状态、时长
struct CallMeta: Codable, Hashable {
    var media: String?
    var state: String?
    var secs: Int?
    /// 谁打出去的（客户端靠它把这条记录摆到左边还是右边）
    var from: String?
    var to: String?
}

/* ============================================================ 附近的人 */

/// 附近名单里的一个人
struct NearbyPerson: Decodable, Identifiable, Hashable {
    var id: String
    var nickname: String?
    var avatar: String?
    var gender: String?
    var region: String?
    var bio: String?
    var moodText: String?
    var moments: Int?
    var online: Bool?
    var friend: Bool?
    /// 距离（公里，服务器算好的，一位小数）
    var km: Double?
    /// 几分钟前报的位置
    var minutes: Int?

    var name: String { (nickname?.isEmpty == false) ? nickname! : "附近的人" }
    var isFemale: Bool { (gender ?? "") == "female" }
    /// 距离文字：照参考图那种微信写法 —— 不到 1 公里「500米以内」，超过就「1.2公里以内」
    var distanceText: String {
        guard let km = km else { return "" }
        if km < 1 {
            let m = max(100, Int(ceil(km * 1000 / 100)) * 100)      // 往大取到 100 米
            return "\(m)米以内"
        }
        return String(format: "%.1f公里以内", km)
    }
    var timeText: String {
        guard let m = minutes else { return "" }
        if m <= 0 { return "刚刚" }
        if m < 60 { return "\(m) 分钟前" }
        return "\(m / 60) 小时前"
    }
}

private struct NearbyPayload: Decodable {
    var people: [NearbyPerson]
    /// 5 公里内没人时：20 公里内有几个（提示「扩大范围」用）
    var wider: Int?
    var maxKm: Double?
}
private struct NearbyHelloPayload: Decodable { var chatId: String?; var text: String? }

/// 摇一摇的结果：摇到人就是 matched，没人同时在摇就是 nil
struct ShakeResult: Decodable {
    var matched: NearbyPerson?
    /// 现在有几台设备在摇（微信也会提示「同时有 N 人在摇」）
    var shaking: Int?
}

/* ---------------- 直播专场 ---------------- */
private struct LivePayload: Decodable { var rooms: [LiveRoom] }
private struct LiveJoinPayload: Decodable { var watching: Int? }
private struct LiveLikePayload: Decodable { var likes: Int? }
private struct GamesPayload: Decodable { var items: [MiniGame] }

/// 小游戏：玩法写在客户端，服务器只发列表（后台能改 data/games.json）
struct MiniGame: Decodable, Identifiable, Hashable {
    var id: String
    var label: String?
    var desc: String?
    var icon: String?
    var kind: String?
    var enabled: Bool?
    /// 网页小游戏的地址（服务器 /games/xxx/index.html）——
    /// 这一版 4 款游戏都是网页的，App 用内置浏览器全屏打开
    var url: String?
}

/* ---------------- 视频号 ---------------- */
/// 视频号的后台可调样式（后台「视频号」面板里改）
struct FeedStyle: Decodable, Hashable {
    var avatar: Double?
    var nameSize: Double?
    var descSize: Double?
    var musicSize: Double?
    var railIcon: Double?
    var railGap: Double?
    var padBottom: Double?
}

/// 视频号的开关
struct FeedFlags: Decodable, Hashable {
    var allowPublish: Bool?
    var allowTrim: Bool?
    var showRail: Bool?
    var autoPlay: Bool?
}

private struct FeedPayload: Decodable {
    var items: [FeedItem]
    var style: FeedStyle?
    var flags: FeedFlags?
}
private struct FeedLikePayload: Decodable { var liked: Bool?; var likes: Int? }
private struct FeedCommentPayload: Decodable { var comments: Int? }
private struct FeedCommentsPayload: Decodable { var comments: [FeedCommentItem]?; var count: Int? }
private struct FeedSeriesPayload: Decodable { var series: String?; var name: String?; var items: [FeedItem]? }
private struct FeedFavoritePayload: Decodable { var favorited: Bool?; var favorites: Int? }
/// 视频号一条评论
struct FeedCommentItem: Decodable, Hashable, Identifiable {
    var id: String
    var name: String?
    var avatar: String?
    var text: String?
    var at: String?
}
private struct FeedPublishPayload: Decodable { var id: String?; var video: String? }
private struct FeedTrimPayload: Decodable { var url: String?; var width: Int?; var height: Int? }

struct MomentLike: Codable, Hashable {
    var userId: String?
    var nickname: String?
    var at: String?
}

struct MomentComment: Codable, Hashable {
    var id: String?
    var userId: String?
    var nickname: String?
    var replyToName: String?
    var content: String?
    var at: String?
}

/// ⚠ B160+：改成 Codable —— 朋友圈要做**本机缓存**（照微信：进页面先铺缓存再刷、
/// 断网也能看上次那几屏），落盘要能编码。
struct Moment: Codable, Identifiable, Hashable {
    var id: String
    var authorId: String?
    var author: User?
    var content: String?
    var images: [String]?
    /// 每张图的宽高（发表时一起带上来的）：列表一上来就按真实比例把框画好，
    /// 不会再「先 4:3、加载完跳一下」（尺寸跳变）
    var imageSizes: [String: [Int]]?
    /// 朋友圈视频（和微信一样：一条动态要么九张图、要么一条视频）
    var video: String?
    var videoCover: String?
    var videoSeconds: Int?
    var videoW: Int?
    var videoH: Int?
    /// 发表时选的「所在位置」（微信发表页那一行，不填就是空）
    var location: String?
    /// 我置顶的那条动态（置顶的永远排在朋友圈最上面）
    var pinned: Bool?
    var createdAt: String?
    var likes: [MomentLike]?
    var likedByMe: Bool?
    var comments: [MomentComment]?
    var mine: Bool?
}

/// 朋友圈「消息列表」里的一条：谁赞了/评论了我（微信右上角那个小信封点开就是它）
struct MomentNotice: Decodable, Identifiable, Hashable {
    var id: String
    /// like = 赞了 / comment = 评论了 / reply = 回复了我
    var kind: String?
    var at: String?
    var momentId: String?
    var commentId: String?
    /// 评论内容（点赞的话是空串）
    var text: String?
    /// 被点赞/评论的那条动态的正文摘要 + 第一张缩略图
    var preview: String?
    var thumb: String?
    var userId: String?
    var name: String?
    var avatar: String?
    /// 那条动态已经不在了（删了）：微信里点不开
    var deleted: Bool?

    init(id: String, kind: String? = nil, at: String? = nil, momentId: String? = nil,
         commentId: String? = nil, text: String? = nil, preview: String? = nil,
         thumb: String? = nil, userId: String? = nil, name: String? = nil,
         avatar: String? = nil, deleted: Bool? = nil) {
        self.id = id; self.kind = kind; self.at = at; self.momentId = momentId
        self.commentId = commentId; self.text = text; self.preview = preview
        self.thumb = thumb; self.userId = userId; self.name = name
        self.avatar = avatar; self.deleted = deleted
    }

    /// 服务器 WebSocket 直接推过来的是裸字典，这里自己解一遍
    init(json: [String: Any]) {
        self.init(id: (json["id"] as? String) ?? UUID().uuidString,
                  kind: json["kind"] as? String,
                  at: json["at"] as? String,
                  momentId: json["momentId"] as? String,
                  commentId: json["commentId"] as? String,
                  text: json["text"] as? String,
                  preview: json["preview"] as? String,
                  thumb: json["thumb"] as? String,
                  userId: json["userId"] as? String,
                  name: json["name"] as? String,
                  avatar: json["avatar"] as? String,
                  deleted: json["deleted"] as? Bool)
    }
}

private struct MomentNoticesPayload: Decodable {
    var items: [MomentNotice]?
    var unread: Int?
    var total: Int?
}

private struct ChatsPayload: Decodable { var chats: [Chat] }
private struct ChatPayload: Decodable { var chat: Chat? }
private struct ChatMembersPayload: Decodable {
    var members: [User]?
    var ownerId: String?
    var createdAt: String?
    var avatar: String?
}
private struct PinPayload: Decodable { var pinned: Bool?; var forced: Bool? }
private struct ChatInfoPayload: Decodable { var name: String?; var announce: String? }
private struct MutePayload: Decodable { var muted: Bool? }
private struct GroupActionPayload: Decodable { var memberCount: Int?; var left: Bool?; var dismissed: Bool? }
private struct SearchPayload: Decodable { var messages: [FoundMessage] }
private struct BankCardsPayload: Decodable { var cards: [BankCard]? }
private struct SendPayload: Decodable { var sent: Bool?; var id: String? }

/// 银行卡（卡号只回后四位）
    struct BankCard: Decodable, Identifiable, Hashable {
        /* 微信银行卡那页要的：卡类型、免密支付、限额、脱敏手机号 */
        var type: String?
        var noPin: Bool?
        var single: Double?
        var day: Double?
        var phoneMask: String?
    var id: String
    var bank: String?
    var holder: String?
    var tail: String?

    var title: String { (bank ?? "银行卡") + " 尾号" + (tail ?? "****") }
}

/// 「查找聊天记录」搜出来的那一条
struct FoundMessage: Decodable, Identifiable, Hashable {
    var id: String
    var seq: Int?
    var kind: String?
    var content: String?
    var createdAt: String?
    var senderId: String?
    var senderName: String?
}
private struct UsersPayload: Decodable { var users: [User] }
private struct MessagesPayload: Decodable {
    var chat: Chat?
    var messages: [Message]
    var hasMore: Bool?
}
private struct MessagePayload: Decodable { var message: Message? }
private struct CreditScorePayload: Decodable { var score: CreditScore }

/// 安全分（服务端按真实记录算：资料 / 登录设备 / 转账 / 记账 / 安全事件）
struct CreditScore: Decodable, Hashable {
    struct Item: Decodable, Hashable {
        var label: String
        var ok: Bool
        var tip: String?
    }
    struct Dim: Decodable, Hashable, Identifiable {
        var key: String
        var label: String
        var score: Int
        var max: Int
        var items: [Item]?
        var id: String { key }
    }
    struct Stats: Decodable, Hashable {
        var deviceCount: Int?
        var sentCount: Int?
        var successCount: Int?
        var expiredCount: Int?
        var ledgerCount: Int?
    }
    var score: Int
    var level: String
    var min: Int
    var max: Int
    var percent: Int
    var updatedAt: String?
    var dims: [Dim]
    var tips: [String]
    var stats: Stats?
    /// 安全分当前能动的钱（2026-10-15 用户要求「安全分要真实管控用户的」）——
    /// 服务器在 /api/me/score 里一起下发；老服务器没有这个字段就是 nil
    var scoreLimit: ScoreLimit?

    struct ScoreLimit: Decodable, Hashable {
        /// 算分用的分数 / 档位名
        var score: Int?
        var level: String?
        /// 单笔 / 单日额度（元）
        var single: Double?
        var day: Double?
        /// true = 支付类（转账 / 红包 / 收付款 / 提现）被暂停
        var block: Bool?
    }
}
private struct ContactsPayload: Decodable {
    var friends: [User]
    var incoming: [User]?
    var outgoing: [User]?
    /// 刚通过、还留在「新的朋友」里显示「已添加」的人
    var added: [User]?
}
private struct MePayload: Decodable { var user: User? }
private struct UserPayload: Decodable { var user: User? }
private struct LoginPayload: Decodable { var user: User? }
private struct SessionPayload: Decodable { var authenticated: Bool?; var user: User? }
private struct PhoneCodePayload: Decodable { var sent: Bool?; var devCode: String?; var nickname: String? }
private struct CaptchaPayload: Decodable { var id: String?; var svg: String? }
private struct PairStartPayload: Decodable { var code: String?; var expiresIn: Int? }
private struct PairStatusPayload: Decodable { var status: String?; var user: User?; var token: String? }
private struct MomentsPayload: Decodable {
    var moments: [Moment]
    var hasMore: Bool?
    var unread: Int?
    var total: Int?
    /// 朋友圈「消息列表」的未读数（右上角小信封上的红点）
    var noticeUnread: Int?
    /// 看别人的朋友圈时：这个人设的可见范围（all / 3d / 6m）——
    /// App 用它显示「朋友仅展示最近三天的朋友圈」那句提示（微信有这一句）
    var range: String?
}
private struct BrandingPayload: Decodable { var branding: BrandInfo? }
private struct BadgesPayload: Decodable { var badges: [String: String]? }
private struct EndpointsPayload: Decodable { var endpoints: [String]? }

/* ---------------- 版本更新 + 弹窗公告（服务端 /api/version 下发） ---------------- */
struct AppUpdateInfo: Decodable, Equatable {
    var version: String?
    var notes: String?
    var force: Bool?
    var url: String?
    var downloadPage: String?
}
struct NoticeInfo: Decodable, Equatable {
    var title: String?
    var content: String?
    var kind: String?          // popup=每次打开 / daily=每天一次 / once=只弹一次
    var startAt: String?
    var endAt: String?
    var minVersion: String?
    var maxVersion: String?
}
private struct VersionPayload: Decodable {
    var app: AppUpdateInfo?
    var notice: NoticeInfo?
}

struct BrandInfo: Decodable, Hashable {
    var appName: String?
    var logo: String?
    /// 服务器上配的「默认聊天背景」（用户自己没设时用它）
    var chatBackground: String?
    var fontScale: Double?
    var accentColor: String?
    /// 通话用的 ICE 服务器（后台「语音通话」里配的，跨网络需要 TURN 时填这儿）
    var iceServers: String?
    /// 登录页外观（后台「🎨 登录页」里配的）
    var login: LoginBrand?
    /// 服务器有没有开「登录滑动验证」（安全验证那一块显不显示由它决定）
    var sliderLogin: Bool?
    /// 后台配的启动页图片（没有就用 App 包里那张 splash.png 兜底）
    var splash: String?
}

struct LoginBrand: Decodable, Hashable {
    var accent: String?
    var accent2: String?
    var disabledAccent: String?
    var disabledGray: String?
    var bg: String?
    var card: String?
    var text: String?
    var sub: String?
    /// 深色模式下登录页的文字颜色（后台「深色·文字」）
    var darkText: String?
    /// 深色模式下的页面底色 / 卡片底色（后台「登录页 → 深色·背景 / 深色·卡片」）
    var darkBg: String?
    var darkCard: String?
    var bgImage: String?
    var appName: String?
    var subTitle: String?
    var logo: String?
    var terms: String?
    var privacy: String?
}



struct PlusItem: Decodable, Identifiable, Hashable {
    var id: String?
    var label: String?
    var icon: String?
    var action: String?
    var enabled: Bool?
}

/// 聊天输入框上面那一排「快捷按钮」：后台（管理 → 聊天快捷）能增删、排序、改名、开关
struct QuickChip: Codable, Identifiable, Hashable {
    var id: String
    var label: String
    var action: String
    var enabled: Bool

    /// 拉不到后台配置时的兜底：和原来的那一排一模一样
    static let defaults: [QuickChip] = [
        QuickChip(id: "q01", label: "图片", action: "photo", enabled: true),
        QuickChip(id: "q02", label: "拍摄", action: "camera", enabled: true),
        QuickChip(id: "q03", label: "位置", action: "location", enabled: true),
        QuickChip(id: "q04", label: "文件", action: "file", enabled: true),
        QuickChip(id: "q05", label: "转账", action: "transfer", enabled: true),
        QuickChip(id: "q06", label: "红包", action: "redpacket", enabled: true),
        QuickChip(id: "q07", label: "名片", action: "card", enabled: true)
    ]
    /// 能配哪些动作（和「＋」面板同一套，点了走同一个处理）
    static let actions = ["photo", "camera", "location", "file", "transfer", "redpacket",
                          "card", "gift", "music", "videocall", "voice", "favorite"]
    static let actionNames: [String: String] = [
        "photo": "图片", "camera": "拍摄", "location": "位置", "file": "文件",
        "transfer": "转账", "redpacket": "红包", "card": "名片", "gift": "礼物",
        "music": "音乐", "videocall": "视频通话", "voice": "语音输入", "favorite": "收藏"
    ]
}

/// 输入框右边那个「＋」按钮的外观（管理里能换颜色 / 大小 / 图片）
struct PlusButtonCfg: Codable, Hashable {
    var color: String = ""
    var size: Double = 0
    var image: String = ""
}

struct Gift: Decodable, Identifiable, Hashable {
    var id: String
    var name: String?
    var icon: String?
    var price: Double?
    var category: String?
}

struct StickerPack: Decodable, Hashable {
    var id: String?
    var name: String?
    var icon: String?
    var stickers: [String]?
}

struct StatusItem: Decodable, Hashable {
    var id: String?
    var icon: String?
    var label: String?
    var color: String?
    var color2: String?
}

struct StatusCategory: Decodable, Hashable {
    var id: String?
    var name: String?
    /// 分类自己的底色（后台「状态」页配的），格子没单独配色就用它
    var color: String?
    var enabled: Bool?
    var items: [StatusItem]?
}

/* ---------------- 我的状态（微信那套：24 小时过期 / 谁看过 / 结束状态） ---------------- */

/// 看过我状态的人
struct StatusViewer: Decodable, Hashable {
    var userId: String?
    var name: String?
    var avatar: String?
    var at: String?
}

/// 我的状态详情：还在不在、是什么、还剩几个小时、谁看过
struct MyStatus: Decodable {
    var alive: Bool?
    var moodText: String?
    var moodIcon: String?
    var moodColor: String?
    var moodColor2: String?
    var moodLabel: String?
    var moodCaption: String?
    var hoursLeft: Int?
    var createdAt: String?
    var viewerCount: Int?
    var views: [StatusViewer]?

    var isAlive: Bool { alive ?? false }
    /// 大卡片上那一行：优先显示「说点什么」，没有就显示状态名
    var shownText: String {
        let cap = (moodCaption ?? "").trimmingCharacters(in: .whitespaces)
        if !cap.isEmpty { return cap }
        return (moodLabel ?? moodText ?? "")
    }
}

/// 状态配色：后台配了就用，没配就用分类色，第二个色自动调亮一点做渐变
enum MoodColor {
    /// 这个颜色偏暗吗？顶部铺状态色时，用它决定名字/文字用白还是黑（微信也是这么处理的）
    static func isDark(_ hex: String) -> Bool {
        let c = clean(hex)
        guard !c.isEmpty, let v = UInt32(c.dropFirst(), radix: 16) else { return false }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        func lin(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        return l < 0.45
    }

    /// "#6f8a38" / "6f8a38" → "#6F8A38"；拿不准就给空串
    static func clean(_ raw: String?) -> String {
        var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, UInt32(s, radix: 16) != nil else { return "" }
        return "#" + s.uppercased()
    }

    /// 同色系调亮 / 调暗一点（给渐变的第二格用）
    static func shift(_ hex: String, to light: Bool) -> String {
        let c = clean(hex)
        guard !c.isEmpty, let v = UInt32(c.dropFirst(), radix: 16) else { return "" }
        var r = Double((v >> 16) & 0xFF)
        var g = Double((v >> 8) & 0xFF)
        var b = Double(v & 0xFF)
        let k = light ? 0.28 : -0.18
        let mix = light ? 255.0 : 0.0
        r += (mix - r) * k
        g += (mix - g) * k
        b += (mix - b) * k
        let out = (UInt32(max(0, min(255, r))) << 16)
            | (UInt32(max(0, min(255, g))) << 8)
            | UInt32(max(0, min(255, b)))
        return String(format: "#%06X", out)
    }
}

/// 发现页的一行（后台可以自由增删改）
struct DiscoverItem: Decodable, Identifiable, Hashable {
    var id: String
    var label: String
    var icon: String?
    var svg: String?
    var color: String?
    var action: String?
    var group: Int?
    var enabled: Bool?
}

private struct StickersPayload: Decodable { var packs: [StickerPack]? }

/* ------------------------------------------------------------ 新闻（星联世界页）
   服务端把国内的源（腾讯 / 头条 / 新浪 / 微博 / 百度）统一成这一份结构。
   有图的（腾讯、头条、新浪）走大图 / 右缩略图的版式；没图的（微博、百度热搜）
   走带名次的榜单版式 —— 两种都是腾讯新闻 App 里的样子。 */
struct NewsChannel: Decodable, Identifiable, Hashable {
    var id: String
    var label: String
    var desc: String?
}

struct NewsItem: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var summary: String?
    var source: String?
    var url: String?
    var img: String?
    /// 热度值（微博 / 百度 / 头条有，腾讯和新浪没有）
    var hot: Double?
    /// 榜上的名次（1 就是第一条）
    var rank: Int?
    /// 「热 / 新 / 沸」那种小标
    var tag: String?
    /// 毫秒时间戳（有的源不给，就是 0）
    var time: Double?

    var link: String { url ?? "" }
    var cover: String { img ?? "" }
    var src: String { (source?.isEmpty == false) ? source! : "星联世界" }
    var tagText: String { tag ?? "" }
    var hotValue: Double { hot ?? 0 }
    var order: Int { rank ?? 0 }
    var at: Double { time ?? 0 }
}

struct NewsFeed: Decodable {
    var list: [NewsItem]?
    var source: String?
    var channels: [NewsChannel]?
    var updatedAt: Double?
    /// 这个源一共多少条（「换一批」用它判断有没有到底）
    var total: Int?

    var items: [NewsItem] { list ?? [] }
    var tabs: [NewsChannel] { channels ?? [] }
}
/// 「我的表情」（微信「我 → 表情」那套）：我添加的表情包 + 我自己添加的单个表情 + 最近使用
struct StickerMine: Decodable, Hashable {
    var packs: [StickerPack]?
    var singles: [String]?
    var recent: [String]?
    var packList: [StickerPack] { packs ?? [] }
    var singleList: [String] { singles ?? [] }
    var recentList: [String] { recent ?? [] }
}
private struct StickerShopPayload: Decodable {
    var packs: [StickerPack]?
    var mine: StickerMine?
    var thirdParty: ThirdParty?
    struct ThirdParty: Decodable { var provider: String?; var enabled: Bool?; var limit: Int? }
}
private struct StatusesPayload: Decodable { var categories: [StatusCategory]? }
private struct DiscoverPayload: Decodable { var items: [DiscoverItem] }

/* ---------------- 服务页（我 → 服务，后台「服务页」模块下发） ---------------- */

/// 绿卡的一半：收付款 / 钱包
struct ServiceHalf: Decodable, Hashable {
    var label: String
    var sub: String?
    var icon: String?
    var svg: String?
    var action: String?
}

/// 绿卡本身（底色 + 左右两半）
struct ServiceCard: Decodable, Hashable {
    var enabled: Bool?
    var bg: String?
    var left: ServiceHalf?
    var right: ServiceHalf?
}

/// 一个分类：标题 + 里面的格子（格子复用发现页那套字段）
/// 版块只给「上 / 下」两个值（块与块之间的空隙；nil = 用默认：上 0 / 下 8）
struct ServiceGroupStyle: Decodable, Hashable {
    var gapTop: Double?
    var gapBottom: Double?
}

struct ServiceGroup: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var enabled: Bool?
    var style: ServiceGroupStyle?
    var items: [DiscoverItem]?
}

/// 服务页的样式：绿卡背景图 / 图标大小 / 各处字体的大小和颜色（后台「服务页 → 样式」里配）
struct ServiceStyle: Decodable, Hashable {
    var cardImage: String?
    var cardTextColor: String?
    var cardTextSize: Double?
    var cardSubSize: Double?
    var curSize: Double?
    var cardSubOpacity: Double?
    var iconSize: Double?
    var gridTitleSize: Double?
    var gridTitleColor: String?
    var gridTextSize: Double?
    var gridTextColor: String?
    var maskAmount: Bool?       // 绿卡右边的零钱打成 ¥****
    var maskReveal: Bool?       // 点一下能不能看

    /// 默认值 = 照参考图量出来的那套
    var icon: CGFloat { CGFloat(iconSize ?? 28) }
    var cardNameSize: CGFloat { CGFloat(cardTextSize ?? 18) }
    var cardSubSizeV: CGFloat { CGFloat(cardSubSize ?? 12) }
    var curFontSize: CGFloat { CGFloat(curSize ?? 0) }
    var cardSubOpacityV: Double { cardSubOpacity ?? 0.5 }
    var titleSize: CGFloat { CGFloat(gridTitleSize ?? 14) }
    var textSize: CGFloat { CGFloat(gridTextSize ?? 13) }
    var cardText: Color { Color(hexString: cardTextColor ?? "#FFFFFF", fallback: 0xFFFFFF) }
    /// 标题颜色：还是默认值就跟主题走（浅色 #7A7A7A / 深色 #8A8A8A）
    var titleColor: Color {
        let v = (gridTitleColor ?? "#7A7A7A").uppercased()
        if v == "#7A7A7A" { return Color.dyn(0x7A7A7A, 0x8A8A8A) }
        return Color(hexString: v, fallback: 0x7A7A7A)
    }
    /// 格子文字颜色：留空就跟主题
    var gridText: Color {
        if let c = gridTextColor, !c.isEmpty { return Color(hexString: c, fallback: 0x191919) }
        return C.label
    }
    /// 尺寸变了，卡片和格子跟着长，不把字挤出去
    var cardHeight: CGFloat { 144 + (icon - 28) + (cardNameSize - 18) + (cardSubSizeV - 12) }
    var cellHeight: CGFloat { 92 + (icon - 28) + (textSize - 13) }
    var titleHeight: CGFloat { 48 + (titleSize - 14) }
}

/// 整页服务页的配置
/// 收付款码（付款码 / 收款码都用这一个）
struct PayCodeInfo: Decodable {
    var code: String?
    var grouped: String?          // 每 4 位空一格（银行卡那种排版）
    var url: String?              // 二维码里装的内容
    var expiresAt: Double?
    var seconds: Int?
    var rows: [String]?           // 二维码点阵
    var size: Int?
    var amount: Double?           // 收款码「设置金额」
    var user: User?
}

/// 扫到的码是谁的、要收多少钱
struct PayScanInfo: Decodable, Identifiable {
    var kind: String              // pay = 付款码（我付给码的主人）/ receive = 收款码
    var amount: Double?
    var user: User?
    var id: String { "\(kind)-\(user?.id ?? "")-\(amount ?? 0)" }
}

/// 付款结果
struct PayCollectResult: Decodable {
    var balance: Double?
    var amount: Double?
    var payee: User?
}

/// 服务页底部那块（账单卡 + 右上角「⋯」菜单）的文案：后台「服务页 → 底部」里配，
/// 留空就用 App 里的默认值（以前这些字全都是写死在 App 里的）
struct ServiceBottom: Decodable, Hashable {
    var billTitle: String? = nil
    var billAll: String? = nil
    var billRecharge: String? = nil
    var billEmpty: String? = nil
    var moreRefresh: String? = nil
    var moreRecharge: String? = nil
    var moreCancel: String? = nil
    /// 「XX 还没接后端」这句提示，{label} 会替换成格子的名字
    var soonTip: String? = nil
}

struct ServiceConfig: Decodable, Hashable {
    var title: String?
    var card: ServiceCard?
    var bottom: ServiceBottom?
    var style: ServiceStyle?
    var groups: [ServiceGroup]?
}

/* ---------------- 钱包页（我 → 服务 → 钱包，后台「钱包页」模块下发） ---------------- */

/// 钱包页的一行
struct WalletItem: Decodable, Identifiable, Hashable {
    var id: String
    var label: String
    var value: String?
    var valueKind: String?      // "balance" = 这一行的数值现算这个人的零钱
    var note: String?           // 小字，比如「收益率 1.01%」
    var icon: String?
    var svg: String?
    var color: String?
    var action: String?
    var mask: Bool?             // 这一行的金额要不要打星号
    var enabled: Bool?
}

/// 钱包页的一张白卡
struct WalletGroup: Decodable, Identifiable, Hashable {
    var id: String
    var enabled: Bool?
    var items: [WalletItem]?
}

/// 右上角那个按钮（默认是「账单」）
struct WalletRight: Decodable, Hashable {
    var label: String?
    var action: String?
}

/// 底部的蓝色链接（身份信息 / 支付设置）
struct WalletFoot: Decodable, Identifiable, Hashable {
    var id: String
    var label: String
    var action: String?
    var enabled: Bool?
}

/// 钱包页的样式（行高 / 图标 / 字体 / 颜色）
struct WalletStyle: Decodable, Hashable {
    var rowHeight: Double?
    var iconSize: Double?
    var iconLeft: Double?
    var textLeft: Double?
    var rightInset: Double?
    var labelSize: Double?
    var valueSize: Double?
    var curSize: Double?
    var noteSize: Double?
    var footerSize: Double?
    var groupGap: Double?
    var dividerInset: Double?
    var labelColor: String?
    var valueColor: String?
    var noteColor: String?
    var footerColor: String?
    var maskAmount: Bool?       // 金额打成 ¥****
    var maskReveal: Bool?       // 点一下能不能看

    var row: CGFloat { CGFloat(rowHeight ?? 56.3) }
    var icon: CGFloat { CGFloat(iconSize ?? 20) }
    var iconX: CGFloat { CGFloat(iconLeft ?? 18) }
    var textX: CGFloat { CGFloat(textLeft ?? 56.7) }
    var rightPad: CGFloat { CGFloat(rightInset ?? 18) }
    var labelFont: CGFloat { CGFloat(labelSize ?? 17) }
    var valueFont: CGFloat { CGFloat(valueSize ?? 16) }
    var curFontSize: CGFloat { CGFloat(curSize ?? 0) }
    var noteFont: CGFloat { CGFloat(noteSize ?? 13) }
    var footFont: CGFloat { CGFloat(footerSize ?? 13) }
    var gap: CGFloat { CGFloat(groupGap ?? 12) }
    var divider: CGFloat { CGFloat(dividerInset ?? 56) }
    /// 行标题：留空就跟主题
    var labelColorV: Color {
        if let c = labelColor, !c.isEmpty { return Color(hexString: c, fallback: 0x191919) }
        return C.label
    }
    var valueColorV: Color {
        let v = (valueColor ?? "#1A1A1A").uppercased()
        if v == "#1A1A1A" { return C.label }
        return Color(hexString: v, fallback: 0x1A1A1A)
    }
    var noteColorV: Color { Color(hexString: noteColor ?? "#FA9D3B", fallback: 0xFA9D3B) }
    var footerColorV: Color { Color(hexString: footerColor ?? "#576B95", fallback: 0x576B95) }
    /// 金额打星号（默认开）
    var mask: Bool { maskAmount ?? true }
    var canReveal: Bool { maskReveal ?? true }
}

/// 整页钱包页的配置
struct WalletConfig: Decodable, Hashable {
    var title: String?
    var right: WalletRight?
    var groups: [WalletGroup]?
    var footer: [WalletFoot]?
    var style: WalletStyle?
    var balance: Double?
    /// 没实名：金额被服务端打成 ¥****，钱的动作也全拦着（和微信一样）
    var locked: Bool?
    var needRealName: Bool?
    var isLocked: Bool { (locked ?? false) || (needRealName ?? false) }
}

/* ---------------- 小游戏好友榜（GET /api/games/rank） ---------------- */

/// 榜单里的一行（我 + 我的好友）
struct GameRankRow: Decodable, Hashable, Identifiable {
    var id: String?
    var name: String?
    var avatar: String?
    var score: Int?
    var me: Bool?
    var rank: Int?

    var key: String { (id?.isEmpty == false) ? id! : ((name ?? "") + "\(rank ?? 0)") }
    var scoreText: Int { score ?? 0 }
    var isMe: Bool { me == true }
}

struct GameRank: Decodable, Hashable {
    var game: String?
    var list: [GameRankRow]?
    var total: Int?
    var myRank: Int?
    var myScore: Int?

    var rows: [GameRankRow] { list ?? [] }
}

/* ---------------- 账单（钱包页右上角「账单」进来，数据来自 /api/bills） ---------------- */

/// 一条账单（就是一笔转账，带对方是谁）
struct BillRecord: Decodable, Identifiable, Hashable {
    var id: String
    var chatId: String?
    var amount: Double
    var note: String?
    var method: String?
    var status: String?
    var createdAt: String?
    var expiresAt: Double?
    var receivedAt: String?
    var refundedAt: String?
    var direction: String?          // out = 我转出去 / in = 别人转给我
    var peerId: String?
    var peerName: String?
    var peerAvatar: String?
    /// 这一笔是什么（服务端会给：redpacket 红包 / recharge 充值 / withdraw 提现 / member 会员；
    /// 转账没有这个字段）。收支统计里就是按它分类的。
    var walletKind: String?
    /// 提现的手续费（有的话）
    var fee: Double?

    var mine: Bool { direction != "in" }
    var peer: String { (peerName?.isEmpty == false) ? peerName! : "好友" }
    var stateText: String {
        let st = status ?? "pending"
        if mine {
            if st == "received" { return "对方已收款" }
            if st == "refunded" { return "已退回" }
            return "待对方收款"
        }
        if st == "received" { return "已收款" }
        if st == "refunded" { return "已退回" }
        return "待收款"
    }
}

/// 账单汇总（in 是关键字，映射成 inSum）
struct BillSummary: Decodable, Hashable {
    var out: Double
    var inSum: Double
    var pendingOut: Int
    var pendingIn: Int
    var count: Int

    enum CodingKeys: String, CodingKey {
        case out
        case inSum = "in"
        case pendingOut, pendingIn, count
    }
}

struct BillsPayload: Decodable, Hashable {
    var bills: [BillRecord]
    var months: [String]?
    var summary: BillSummary?
    var month: String?
    var style: BillsPageStyle?
    var faq: [BalanceFaq]?
}

/// 账单页外观（后台「账单页」里调）
struct BillsPageStyle: Decodable, Hashable {
    var iconSize: Double?
    var titleSize: Double?
    var timeSize: Double?
    var amountSize: Double?
    var curSize: Double?
    var amountWeight: Double?
    var showCur: Bool?
    var monthSize: Double?
    var sumSize: Double?
    var rowHeight: Double?

    var icon: CGFloat { CGFloat(iconSize ?? 48) }
    var titleFont: CGFloat { CGFloat(titleSize ?? 17) }
    var timeFont: CGFloat { CGFloat(timeSize ?? 13) }
    var amountFont: CGFloat { CGFloat(amountSize ?? 16) }
    var curFontSize: CGFloat { CGFloat(curSize ?? 0) }
    /// 金额字重：300 细 / 400 常规 / 500 中 / 600 粗（账单页默认 400，比钱包页细）
    var amountWeightV: Font.Weight {
        switch Int(amountWeight ?? 400) {
        case ..<350: return .light
        case 350..<450: return .regular
        case 450..<550: return .medium
        default: return .semibold
        }
    }
    /// 每行金额要不要带 ¥（默认不带，参考图里只显示 +/− 和数字）
    var showCurV: Bool { showCur ?? false }
    var monthFont: CGFloat { CGFloat(monthSize ?? 15) }
    var sumFont: CGFloat { CGFloat(sumSize ?? 13) }
    var row: CGFloat { CGFloat(rowHeight ?? 80) }
}

/* ---------------- 零钱页（钱包页点「零钱」进来，后台「零钱页」模块下发） ---------------- */

struct BalanceButton: Decodable, Hashable {
    var label: String?
    var action: String?
}

struct BalanceLink: Decodable, Identifiable, Hashable {
    var id: String
    var label: String
    var action: String?
    var enabled: Bool?
}

struct BalanceFaq: Decodable, Hashable {
    var q: String
    var a: String
}

struct BalanceStyle: Decodable, Hashable {
    var bg: String?
    var circleSize: Double?
    var circleColor: String?
    var yenSize: Double?
    var yenColor: String?
    var titleSize: Double?
    var amountSize: Double?
    var curSize: Double?
    var noteSize: Double?
    var noteColor: String?
    var padTop: Double?
    var gapTitle: Double?
    var gapAmount: Double?
    var gapNote: Double?
    var btnWidth: Double?
    var btnHeight: Double?
    var btnRadius: Double?
    var rechargeBg: String?
    var rechargeInk: String?
    var withdrawBg: String?
    var withdrawInk: String?
    var linkSize: Double?
    var linkColor: String?
    var footerSize: Double?
    var footerColor: String?

    var circle: CGFloat { CGFloat(circleSize ?? 64) }
    var yenFont: CGFloat { CGFloat(yenSize ?? 24) }
    var titleFont: CGFloat { CGFloat(titleSize ?? 18) }
    var amountFont: CGFloat { CGFloat(amountSize ?? 64) }
    var curFont: CGFloat { CGFloat(curSize ?? 28) }
    var noteFont: CGFloat { CGFloat(noteSize ?? 16) }
    var topPad: CGFloat { CGFloat(padTop ?? 60) }
    var gapTitleV: CGFloat { CGFloat(gapTitle ?? 24) }
    var gapAmountV: CGFloat { CGFloat(gapAmount ?? 16) }
    var gapNoteV: CGFloat { CGFloat(gapNote ?? 20) }
    var btnW: CGFloat { CGFloat(btnWidth ?? 183.7) }
    var btnH: CGFloat { CGFloat(btnHeight ?? 47.7) }
    var btnR: CGFloat { CGFloat(btnRadius ?? 8) }
    var linkFont: CGFloat { CGFloat(linkSize ?? 13) }
    var footFont: CGFloat { CGFloat(footerSize ?? 12) }
    /* 后台配的颜色当浅色用，深色模式自动给对应的深色（后台也能写 "#浅色|#深色" 自己定两套）。
       以前这些是写死的单色 —— 深色模式下整页还是白的，就是这儿。 */
    var pageBg: Color { colorDyn(bg, light: 0xFFFFFF, dark: 0x0B0B0D) }
    var circleColorV: Color { colorDyn(circleColor, light: 0xFFD100, dark: 0xFFD100) }
    var yenColorV: Color { colorDyn(yenColor, light: 0xFFFFFF, dark: 0xFFFFFF) }
    var noteColorV: Color { colorDyn(noteColor, light: 0xEB9400, dark: 0xEB9400) }
    /// 2026-10-17：默认色从微信绿换成品牌色（ui.json 里配了 rechargeBg 还是以配置为准）
    var rechargeBgV: Color { colorDyn(rechargeBg, light: 0xE02F24, dark: 0xE02F24) }
    var rechargeInkV: Color { colorDyn(rechargeInk, light: 0xFFFFFF, dark: 0xFFFFFF) }
    var withdrawBgV: Color { colorDyn(withdrawBg, light: 0xF2F2F2, dark: 0x2C2C2E) }
    var withdrawInkV: Color { colorDyn(withdrawInk, light: 0x313131, dark: 0xEDEDED) }
    var linkColorV: Color { colorDyn(linkColor, light: 0x576B95, dark: 0x7D90A9) }
    var footerColorV: Color { colorDyn(footerColor, light: 0xB3B3B3, dark: 0x8E8E93) }
}

struct BalancePageConfig: Decodable, Hashable {
    var navTitle: String?
    var title: String?
    var note: String?
    var recharge: BalanceButton?
    var withdraw: BalanceButton?
    var links: [BalanceLink]?
    var footer: String?
    var faq: [BalanceFaq]?
    var style: BalanceStyle?
    var balance: Double?
    var frozen: Double?
    /// 没实名：金额被服务端藏起来了（显示 ¥**** + 去实名认证），钱的动作也全拦着
    var locked: Bool?
    var needRealName: Bool?
    var isLocked: Bool { (locked ?? false) || (needRealName ?? false) }
}

private struct PlusPayload: Decodable { var items: [PlusItem]? }
private struct PlusConfigPayload: Decodable {
    var items: [PlusItem]?
    var quick: [QuickChip]?
    var plus: PlusButtonCfg?
}
private struct GiftsPayload: Decodable { var gifts: [Gift]? }
private struct UploadPayload: Decodable {
    var url: String?
    var name: String?
    var bytes: Int?
    var image: Bool?
}

/// 「聊天背景」页的壁纸清单：后台「聊天壁纸」页配的
/// （默认壁纸 + 若干张基础壁纸）。version 变了说明后台换过图。
struct ChatBgPayload: Decodable {
    struct Item: Decodable {
        var path: String?
        var name: String?
    }
    /// 默认壁纸：所有没自己设过背景的人看到的
    var `default`: String?
    var presets: [Item]?
    var version: String?
}

/* ============================================================ 网络 */

enum APIError: LocalizedError {
    case message(String)
    /// 服务端判定这次登录有风险，要求补一次滑动验证（微信那种「需要时才弹」）
    case needSlider
    /// 没实名却动了钱（转账/红包/收付款/零钱）—— 服务端要求先实名（和微信一样）
    case needRealName
    /// 这个账号已经在另一台手机上登录了（手机单点登录，旧手机被顶下线）
    case otherLogin

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .needSlider: return "请完成安全验证"
        case .needRealName: return "根据国家规定，请先完成实名认证"
        case .otherLogin: return "你的账号在另一台设备上登录了"
        }
    }
}

/// 局域网服务器用的是自签名证书，这里直接放行
final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// 上传进度代理：URLSession 每传一段就回调一次，换算成 0…1 的百分比。
/// 挂在单个上传任务上（session.upload(for:fromFile:delegate:)），不影响别的请求。
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Double) -> Void
    private var last = -1.0

    init(_ onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let p = min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        /* 每 2% 报一次就够：报太密会把主线程刷爆（大视频一秒能回调几十次） */
        if p >= 1 || p - last >= 0.02 {
            last = p
            onProgress(p)
        }
    }
}

final class API {
    static let shared = API()

    let session: URLSession
    private let trustDelegate = TrustAllDelegate()

    private(set) var token: String = ""
    /// 主入口：**新公网 IP 直连**（2026-10-07 换的）。
    /// 旧的 206.187.208.79 已经被移动那条线路整个 RST 掉（连上就被掐），
    /// 换成这个 IP 之后直连速度不变、也绕开了那段拦截。
    /// 证书是 TrustAllDelegate 无条件接受的，所以用 IP 访问不受"证书上是域名"的影响。
    /// 主入口：**新公网 IP 直连**（2026-10-07 换的 103.233.254.147）。
    /// 这里刻意**不写域名**：域名要等 DNS 缓存过期（最多 30 分钟）才全量生效，
    /// 写 IP 就是"立刻能用"，不受任何 DNS 缓存影响。
    /// 备用入口里再放域名 —— 域名解析全部跟上之后，它就是更灵活的那个。
    /// 主入口：**国内新服务器直连**（2026-10-08 从香港 103.233.254.147 搬过来的）。
    /// 为什么换：香港那台的公网 IP 被移动整条线路 RST，移动用户根本连不上；
    /// 这台的 IP 在国内、不被拦，实测 https://43.242.194.89:5443 从外网 200、0.12 秒；
    /// 香港那台降级成备用入口，官方服务还活着，只是移动连不上。
    private(set) var server: String = "43.242.194.89"
    /// 备用入口（服务器 /api/endpoints 下发的；本地缓存着，主入口连不上时按顺序切）。
    private(set) var backups: [String] = API.builtinBackups

    /* ⚠ 2026-10-14：「莫名其妙未连接」的根因之一——
       备用入口里混进了**香港那台旧镜像**（aa.x8iu.com / 103.233.254.147）。
       它不是我们这套的数据（用户 1703 vs 1715、会话 9306 vs 10371，最后同步停在 10-13），
       而且它自己的 /api/endpoints 只指它自己 —— 一旦切过去，不但看到的是旧数据，
       还会**学到它那份地址表，再也回不来**（客户端从此只认香港）。
       所以：入口只允许「我们自己这台 + 内网地址」，别的（香港/旧 IP/旧域名）一律不收。 */
    static let trustedHosts: Set<String> = [
        "43.242.194.89",     // 国内这台（主）
        "u.598218.xyz"       // 同一个 nginx 的域名
    ]
    static func trustedHost(_ s: String) -> Bool {
        var h = s.lowercased()
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        h = h.split(separator: "/").first.map(String.init) ?? h
        h = h.split(separator: ":").first.map(String.init) ?? h
        if h.isEmpty { return false }
        if trustedHosts.contains(h) { return true }
        /* 内网调试地址照旧放行（口径和 Realtime.isLanHost 一样，这里不跨类调用免得并发告警） */
        if h == "localhost" || h == "127.0.0.1" || h == "::1" { return true }
        if h.hasPrefix("10.") || h.hasPrefix("192.168.") { return true }
        if h.hasPrefix("172.") {
            let second = Int(h.split(separator: ".").dropFirst().first.map(String.init) ?? "") ?? 0
            return second >= 16 && second <= 31
        }
        return false
    }

    /// 内置的备用入口（**写死在 App 里**，本地缓存冲不掉它）。
    static let builtinBackups: [String] = [
        "43.242.194.89:5443",
        "43.242.194.89:8443",
        "u.598218.xyz"
    ]
    /// 上一次自动换线路的时间：30 秒内只许切一次，免得来回横跳
    private var lastRotate = Date.distantPast

    /// 上一次请求是不是「连不上服务器」。
    /// 离线时界面**照常显示**（用已经拿到的数据），只是不再有新的；
    /// 这个标记就是用来决定要不要在顶上挂那条「网络不可用」的提示。
    private(set) var offline = false

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: cfg, delegate: trustDelegate, delegateQueue: nil)

        /* 本机存的服务器地址通常优先（尊重用户手动填的），
           但**下面这几个是"我们自己历史上用过、现在已知有问题的"**，
           一律丢掉、换成本包内置的那套 —— 否则装了新包也还在连那个连不上的地址：
             · 192.168.2.7 / :5443 —— 早年局域网那台电脑
             · 206.187.208.79 —— 被移动整条线路 RST 掉的旧公网 IP
             · aa.x8iu.com —— 域名本身没问题，但老设备的 DNS 缓存可能还指着旧 IP；
               交给"主入口 + 备用 IP"这套（连不上会自动切），比死守域名稳
           用户手动填过**别的**地址（比如自己的内网 IP）就不动。 */
        let legacyServers: Set<String> = [
            /* ⚠ 2026-10-09 根因确认：iOS 26 的 App 在 ClientHello 里**只带后量子密钥**
               （X25519MLKEM768），而老服务器（香港、以及国内这台原来的 nginx）
               用的 OpenSSL 3.0.2 不认这个算法，直接 handshake failure（alert 40）。
               Safari 会多带一个经典算法，所以浏览器一直没事、App 一直挂。
               国内这台已经换成 **Node 24 / OpenSSL 3.5** 做 TLS 前端（443/5443/8443），
               后量子握手实测已通。所以：**所有老地址一律作废**，强制回到国内这台。 */
            "192.168.2.7:5443", "192.168.2.7", "206.187.208.79",
            "aa.x8iu.com", "aa.x8iu.com:5443",
            "103.233.254.147", "103.233.254.147:5443",
            "43.242.194.89:5443"
        ]
        if let saved = UserDefaults.standard.string(forKey: "chris.server"),
           !saved.isEmpty,
           !legacyServers.contains(API.normalizeServer(saved)),
           API.trustedHost(saved) {          /* 存着香港那台（旧镜像）的，一律纠正回国内这台 */
            server = API.normalizeServer(saved)
        } else {
            UserDefaults.standard.set(server, forKey: "chris.server")
        }
        if let list = UserDefaults.standard.array(forKey: "chris.backups") as? [String] {
            let cached = list.filter { !$0.isEmpty }
            /* ⚠ 内置的那条（Cloudflare 隧道）要永远留在列表最前面 ——
               以前这里直接覆盖，本地缓存一份空列表就把内置的冲掉了。 */
            backups = API.builtinBackups + cached.filter { !API.builtinBackups.contains($0) }
        }
        // 令牌优先从钥匙串读（重装 App 也不掉），读不到再看老地方
        if let saved = Keychain.get("token") {
            token = saved
        } else if let saved = UserDefaults.standard.string(forKey: "chris.token") {
            token = saved
            Keychain.set(saved, for: "token")
        }
    }

    /* ---------------------------------------------------------- 多入口（自动换线路）
       上线以后最怕的不是服务器挂，而是「线路被掐」：用户手机连不上，只会骂软件。
       这里维护一份候选入口（当前地址 + 后台下发的备用地址 + 同域名的另一个端口），
       连不上就自动换下一个再试一次；换通了就记住，用户不用重装、也不用手动改。 */

    /// 候选入口：当前 → 后台下发的备用 → 同域名的另一个端口（443 / 5443 互备）
    var candidates: [String] {
        var list: [String] = [server]
        /* ⚠ 只收「我们自己这台」的入口：香港旧镜像混进来会把 App 带到别的数据上（见 trustedHost） */
        list.append(contentsOf: backups.filter { API.trustedHost($0) })
        for s in list {
            let parts = s.split(separator: ":")
            if parts.count == 2 {
                let host = String(parts[0])
                let port = String(parts[1])
                list.append(host + (port == "5443" ? ":443" : ":5443"))
            } else if !s.isEmpty {
                list.append(s + ":5443")
            }
        }
        var seen = Set<String>()
        return list.filter { !$0.isEmpty && API.trustedHost($0) && seen.insert($0).inserted }
    }

    /// 服务器下发的入口列表（只认「域名:端口」这种写法，最多留 6 条，本地缓存）
    func setBackups(_ list: [String]) {
        var seen = Set<String>()
        let clean = list.map { API.normalizeServer($0) }
            .filter { !$0.isEmpty && API.trustedHost($0) && seen.insert($0).inserted }
        guard !clean.isEmpty else { return }
        backups = Array(clean.prefix(6))
        UserDefaults.standard.set(backups, forKey: "chris.backups")
    }

    /// 换下一条入口。真换了返回 true（调用方可以拿新地址重试一次）
    @discardableResult
    func rotateEndpoint(force: Bool = false) -> Bool {
        let list = candidates
        guard list.count > 1 else { return false }
        let now = Date()
        if !force, now.timeIntervalSince(lastRotate) < 30 { return false }
        lastRotate = now
        let idx = list.firstIndex(of: server) ?? 0
        let next = list[(idx + 1) % list.count]
        guard next != server else { return false }
        server = next
        UserDefaults.standard.set(next, forKey: "chris.server")
        return true
    }

    /// 顺手更新一份备用入口（每次进前台拉一次；老服务器上没这个接口就静默跳过）
    func loadEndpointList() async {
        guard let payload: EndpointsPayload = try? await get("/api/endpoints", as: EndpointsPayload.self) else { return }
        if let list = payload.endpoints { setBackups(list) }
    }

    /// 版本信息 + 弹窗公告（App 启动/回前台各拉一次；老服务器上没有就整段跳过）
    func versionInfo() async -> (app: AppUpdateInfo?, notice: NoticeInfo?) {
        guard let payload: VersionPayload = try? await get("/api/version", as: VersionPayload.self) else {
            return (nil, nil)
        }
        return (payload.app, payload.notice)
    }

    /* ---------------- 看一看 / 搜一搜 ---------------- */

    /// 看一看：朋友在看的（视频）+ 朋友点赞的动态 + 大家都在看
    func lookAround() async throws -> LookAroundData {
        try await get("/api/lookaround", as: LookAroundData.self)
    }

    /// 搜一搜：一次搜完 联系人 / 群聊 / 朋友圈 / 视频号 / 聊天记录
    func searchAll(_ q: String, scope: String = "all") async throws -> SearchAllData {
        let path = "/api/search?q=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            + "&scope=" + scope
        return try await get(path, as: SearchAllData.self)
    }

    /// 「猜你想搜」：后台 data/search-hot.json 里配的词（后台改完不用出包）
    func searchHot() async throws -> [String] {
        struct Payload: Decodable { var words: [String]? }
        let p: Payload = try await get("/api/search-hot", as: Payload.self)
        return (p.words ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 是不是「压根连不上」这类错（超时 / 拒绝 / DNS / 断网）——只有这类才换线路
    static func isConnectivity(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        switch e.code {
        case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .dataNotAllowed,
             .secureConnectionFailed, .serverCertificateUntrusted:
            return true
        default:
            return false
        }
    }

    /* 一律走加密通道：http 会被同网段的人抓到账号密码。
       证书是自签的，但 App 里带了信任代理（TrustAllDelegate），所以不用装证书也能连。 */
    var base: String { "https://\(server)" }

    /// 把用户填的地址规范化：统一成 https + 5443（老地址 :5180 自动换成 :5443）
    static func normalizeServer(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        v = v.replacingOccurrences(of: "https://", with: "")
        v = v.replacingOccurrences(of: "http://", with: "")
        while v.hasSuffix("/") { v.removeLast() }
        if !v.contains(":") { v += ":5443" }
        v = v.replacingOccurrences(of: ":5180", with: ":5443")
        v = v.replacingOccurrences(of: ":80", with: ":5443")
        return v
    }

    func setServer(_ value: String) {
        let v = API.normalizeServer(value)
        guard !v.isEmpty else { return }
        server = v
        UserDefaults.standard.set(v, forKey: "chris.server")
    }

    func setToken(_ value: String) {
        token = value
        UserDefaults.standard.set(value, forKey: "chris.token")
        Keychain.set(value, for: "token")
    }

    func clearToken() {
        token = ""
        UserDefaults.standard.removeObject(forKey: "chris.token")
        Keychain.remove("token")
    }

    /// /uploads/xxx.png、http://…、data:… 都能转成可加载的地址
    func assetURL(_ path: String) -> URL? {
        if path.isEmpty { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        if path.hasPrefix("data:") { return nil }
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: base + p)
    }

    /// 取图片专用的下载：**带上登录令牌**。
    /// 服务器对 /uploads 的规则是「要么带签名、要么本人已登录」，
    /// 以前这里用的是不带任何请求头的 session.data(from:)，所以只要拿到的是
    /// 没签名/签名过期的老链接，就一律 403 —— 表现就是「头像能看、背景全加载不出来」。
    func imageData(_ url: URL) async throws -> Data {
        try await assetData(url)
    }

    /// 取任意资源（图片 / 语音 / 文件）的字节：**带登录令牌**。
    /// 语音消息要先把 m4a 下载下来才能播（AVAudioPlayer 只能读本地文件）。
    func assetData(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await session.data(for: req)
        return data
    }

    /* ---------------------------------------------------------- 底层请求 */

    /* ---------------------------------------------------------- 连接诊断（临时排查用） */

    /// 诊断用：把域名解析成 IP（看是不是 DNS 的事）
    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let r = res else { return [] }
        defer { freeaddrinfo(res) }
        var out: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = r
        while let cur = p {
            if let sa = cur.pointee.ai_addr {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, cur.pointee.ai_addrlen, &buf, socklen_t(buf.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    out.append(String(cString: buf))
                }
            }
            p = cur.pointee.ai_next
        }
        return out
    }

    /// 诊断用：直接打一次请求，把**原始错误**原样吐出来（不包装成"连不上服务器"）
    /// 传绝对地址就用绝对地址（用来测公网大站 / 明文口，判断是不是 App 自己的网络能力有问题）
    func probeAbsolute(_ urlString: String) async -> String {
        guard let url = URL(string: urlString) else { return "地址无效：\(urlString)" }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            return "成功 HTTP \(code)，\(data.count) 字节"
        } catch {
            let e = error as NSError
            return "失败 \(e.domain) #\(e.code)｜\(e.localizedDescription)"
        }
    }

    func probe(_ path: String) async -> String {
        await probeAbsolute(base + path)
    }

    /// 诊断用：取回一段**文本**（比如 /api/branding，用来确认 ICE/TURN 配置）
    func probeText(_ urlString: String, _ limit: Int = 600) async -> String {
        guard let url = URL(string: urlString) else { return "地址无效" }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let txt = String(data: data, encoding: .utf8) ?? "(非文本)"
            return "HTTP \(code)：" + String(txt.prefix(limit))
        } catch {
            let e = error as NSError
            return "失败 \(e.domain) #\(e.code)｜\(e.localizedDescription)"
        }
    }

    /// 诊断用（老签名，保留兼容）
    func probeOld(_ path: String) async -> String {
        guard let url = URL(string: base + path) else { return "地址拼不出来：\(base + path)" }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            return "成功 HTTP \(code)，\(data.count) 字节"
        } catch {
            let e = error as NSError
            return "失败 \(e.domain) #\(e.code)｜\(e.localizedDescription)"
        }
    }

    /// 诊断用：当前这份候选入口（App 实际会按这个顺序试）
    var diagCandidates: [String] { candidates }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil, retried: Bool = false) async throws -> Any {
        guard let url = URL(string: base + path) else {
            throw APIError.message("服务器地址不正确")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 12
        /* 报一下自己是哪一版（"B456 · 09-23 21:08" 这种）——
           排查「两台手机版本不一样」时，服务器日志里一眼就能看出来 */
        req.setValue(AppInfo.build, forHTTPHeaderField: "X-App-Build")
        /* 设备标识：服务器拿它判断「这次是不是换了设备」，只有换了设备才弹滑动验证 */
        req.setValue(AppInfo.deviceId, forHTTPHeaderField: "X-Device-Id")
        /* 「登录设备管理」那一页要显示的三样：设备名 / 机型 / 系统。
           老客户端没有这三个头，服务器就退回按 UA 猜（只能猜出「浏览器 · iOS」）。 */
        if !AppInfo.deviceName.isEmpty {
            req.setValue(AppInfo.deviceName, forHTTPHeaderField: "X-Device-Name")
        }
        req.setValue(AppInfo.deviceModel, forHTTPHeaderField: "X-Device-Model")
        req.setValue(AppInfo.deviceOs, forHTTPHeaderField: "X-Device-Os")
        /* 端类型：服务器靠它分辨「手机 / 平板 / 电脑」——
           手机是单点登录（新手机一登、旧手机下线），平板电脑可以并存（2026-10-12 加的）。 */
        req.setValue(AppInfo.deviceKind, forHTTPHeaderField: "X-Device-Kind")
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: req)
            offline = false                     // 通了：离线提示撤掉
        } catch {
            /* 连不上（超时 / 拒绝 / DNS / 断网）：自动换一条线路再试一次。
               上线以后线路抽风是常态，卡在「正在连接」比报个错更让人骂。 */
            if !retried, API.isConnectivity(error), rotateEndpoint() {
                return try await request(method, path, body: body, retried: true)
            }
            if API.isConnectivity(error) { offline = true }
            /* 对用户别抛服务器地址出来（那是内部信息，看着也莫名其妙） */
            throw APIError.message("连不上服务器，正在自动换线路…")
        }
        let data = result.0
        let response = result.1

        if let http = response as? HTTPURLResponse,
           let raw = http.value(forHTTPHeaderField: "Set-Cookie"),
           let range = raw.range(of: "chris_chat_session=") {
            let rest = raw[range.upperBound...]
            let value = rest.split(separator: ";").first.map(String.init) ?? ""
            if !value.isEmpty { setToken(value) }
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw APIError.message("服务器返回了看不懂的内容")
        }
        guard let dict = obj as? [String: Any] else {
            throw APIError.message("服务器返回了看不懂的内容")
        }
        if (dict["ok"] as? Bool) != true {
            let msg = (dict["error"] as? String) ?? "请求失败"
            /* 手机单点登录：这个账号已经在另一台手机上登录了（我们这台被顶下线）。
               弹「你的账号在另一台设备上登录」卡片，同时把实时连接停掉
               （本地聊天记录不动，只是不再收新消息）。 */
            if let det = dict["details"] as? [String: Any],
               (det["code"] as? String) == "other_login" {
                let dev = (det["device"] as? String) ?? ""
                Task { @MainActor in OtherLogin.shared.trigger(device: dev) }
                throw APIError.otherLogin
            }
            /* 428 + details.needSlider：服务端要补一次滑动验证（正常登录不会走到这里）。
               单独抛一个类型出来，让登录页能把滑块「弹出来」而不是弹个错误。 */
            if let det = dict["details"] as? [String: Any], (det["needSlider"] as? Bool) == true {
                throw APIError.needSlider
            }
            /* 未实名动了钱：和微信一样弹个对话框，带「去实名认证」入口（聊天不受影响） */
            if let det = dict["details"] as? [String: Any], (det["needRealName"] as? Bool) == true {
                RealNameGate.shared.prompt()
                throw APIError.needRealName
            }
            /* 接口失败都进系统日志 + 打点，重要的汇入服务器（同一条路径 60 秒最多一条）。
               服务器太旧（404）这种一眼就能看出来 —— 「卡包是空的」就是这条查出来的。 */
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLog.error("接口失败 " + path, "HTTP " + String(code) + "｜" + msg)
            throw APIError.message(msg)
        }
        return dict["data"] ?? [String: Any]()
    }

    private func decode<T: Decodable>(_ any: Any, as type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: any, options: [])
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.message("数据解析失败")
        }
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        do {
            let any = try await request("GET", path)
            API.saveOffline(path, any)          // 成功了就留一份，断网时回放
            return try decode(any, as: T.self)
        } catch {
            /* 断网 = 直接回放上一次的数据，别让页面对着一片空白报错。
               （只在"连不上"的时候兜，服务器真的返回错误照样往上抛） */
            if offline, let cached = API.cachedOffline(path) {
                return try decode(cached, as: T.self)
            }
            throw error
        }
    }

    /* ============================================================
       离线兜底缓存（学微信的逻辑）：
       这几个「列表类」接口上一次成功拿到的数据存一份在本机（内存 + 磁盘），
       断网时直接回放 —— 会话列表、通讯录、我的资料、朋友圈照常显示，
       只是收不到新的，顶上挂一条「当前网络不可用」。

       以前：断网时每个页面都报错，冷启动更是会话页/通讯录全空
       （用户反馈的"离线的时候全部画面都掉了"就是这个）。
       只缓存这几个白名单里的接口，别的接口照旧抛错，不会掩盖真实故障。
       ============================================================ */
    private static let offlinePrefixes = ["/api/chats", "/api/contacts", "/api/me",
                                          "/api/moments", "/api/me-page", "/api/plus"]
    private static var offlineMemo: [String: Any] = [:]
    private static let offlineLock = NSLock()

    private static func offlineCacheable(_ path: String) -> Bool {
        offlinePrefixes.contains { path.hasPrefix($0) }
    }

    /// 缓存文件：Application Support/chris-offline/<接口名>.json
    /// （文件名里只留字母数字，路径里的 / 和 ? 一律换成 _）
    private static func offlineFile(_ path: String) -> URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil, create: true) else { return nil }
        let folder = dir.appendingPathComponent("chris-offline", isDirectory: true)
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let safe = String(path.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return folder.appendingPathComponent(safe + ".json")
    }

    /// 存一份（内存 + 磁盘）；不是白名单里的接口直接跳过
    static func saveOffline(_ path: String, _ data: Any) {
        guard offlineCacheable(path), JSONSerialization.isValidJSONObject(data) else { return }
        offlineLock.lock()
        offlineMemo[path] = data
        offlineLock.unlock()
        guard let url = offlineFile(path),
              let raw = try? JSONSerialization.data(withJSONObject: data) else { return }
        try? raw.write(to: url, options: .atomic)
    }

    /// 取一份（内存 → 磁盘）
    static func cachedOffline(_ path: String) -> Any? {
        guard offlineCacheable(path) else { return nil }
        offlineLock.lock()
        let hit = offlineMemo[path]
        offlineLock.unlock()
        if let hit = hit { return hit }
        guard let url = offlineFile(path),
              let raw = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: raw) else { return nil }
        offlineLock.lock()
        offlineMemo[path] = obj
        offlineLock.unlock()
        return obj
    }

    /// 「故障修复」用：把离线兜底缓存整份清掉（会话列表 / 通讯录 / 我的资料 / 朋友圈
    /// 那几份本机缓存），清完页面会重新从服务器拉一遍。**不动聊天记录、不动媒体**。
    @discardableResult
    static func clearOfflineCache() -> Int {
        offlineLock.lock()
        let n = offlineMemo.count
        offlineMemo.removeAll()
        offlineLock.unlock()
        var files = 0
        if let dir = offlineDirectory(),
           let list = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            files = list.count
            for f in list { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        }
        return max(n, files)
    }

    /// 离线缓存目录（Application Support/chris-offline）
    private static func offlineDirectory() -> URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("chris-offline", isDirectory: true)
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: Any], as type: T.Type) async throws -> T {
        let any = try await request("POST", path, body: body)
        return try decode(any, as: T.self)
    }

    private func patch<T: Decodable>(_ path: String, _ body: [String: Any], as type: T.Type) async throws -> T {
        let any = try await request("PATCH", path, body: body)
        return try decode(any, as: T.self)
    }

    /* ---------------------------------------------------------- 业务接口 */

    /* ---------------------------------------------------------- 小游戏排行（网页游戏那层 JS 桥用） */

    /// 报分：只涨不跌。失败就算了 —— 不能因为报分失败把游戏也卡住。
    func gameScore(_ game: String, _ score: Int) async {
        _ = try? await request("POST", "/api/games/score", body: ["game": game, "score": score])
    }

    /// 好友榜单：**直接把服务器那段 JSON 原样交给网页那层画**
    /// （原生这边不再解析一遍，省得两套模型对不齐）
    func gameRankJSON(_ game: String) async -> String {
        let q = game.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? game
        guard let any = try? await request("GET", "/api/games/rank?game=" + q),
              let d = try? JSONSerialization.data(withJSONObject: any, options: []),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }

    /// 和上面一样，但**把好友头像先下成本机、转成 data: 图片**再交给网页。
    /// 为什么必须这样：榜单是在 WKWebView 里画的，而我们的服务器是 IP + 自签证书，
    /// WebView 直接 `<img src="https://43.242...">` 一律加载不出来（头像全空白）。
    /// 走 App 自己的网络层拿到字节再内联，WebView 就能显示了。
    func gameRankJSONWithAvatars(_ game: String) async -> String {
        let q = game.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? game
        guard let any = try? await request("GET", "/api/games/rank?game=" + q),
              var d = any as? [String: Any] else { return "" }
        if var list = d["list"] as? [[String: Any]] {
            for i in list.indices {
                guard let a = list[i]["avatar"] as? String, !a.isEmpty, let u = assetURL(a) else {
                    list[i]["avatar"] = ""
                    continue
                }
                if let data = try? await assetData(u), data.count < 700_000 {
                    list[i]["avatar"] = "data:image/jpeg;base64," + data.base64EncodedString()
                } else {
                    list[i]["avatar"] = ""
                }
            }
            d["list"] = list
        }
        guard let out = try? JSONSerialization.data(withJSONObject: d, options: []),
              let s = String(data: out, encoding: .utf8) else { return "" }
        return s
    }

    /// 好友榜单（原生那一版：游戏详情、游戏排行榜页要用它画列表）
    func gameRank(_ game: String) async -> GameRank? {
        let q = game.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? game
        return try? await get("/api/games/rank?game=" + q, as: GameRank.self)
    }

    /* ---------------------------------------------------------- 音乐：我正在听 / 好友在听 */

    /* ---------------------------------------------------------- App 内的「管理」（ops 用户） */

    /// 管理页要的数据：曲库 + 小游戏/小程序清单
    func manageData() async -> ManageData? {
        try? await get("/api/manage", as: ManageData.self)
    }

    /// 上新音乐 / 改一首歌（id 传空 = 新增）
    func manageSaveMusic(id: String, title: String, artist: String,
                         cover: String, url: String, lyrics: String) async throws {
        var b: [String: Any] = ["title": title, "artist": artist,
                                "cover": cover, "url": url, "lyrics": lyrics]
        if !id.isEmpty { b["id"] = id }
        _ = try await request("POST", "/api/manage/music", body: b)
    }

    /// 换图标（kind = music / miniapp）
    func manageSetIcon(kind: String, id: String, cover: String) async throws {
        _ = try await request("POST", "/api/manage/icon",
                              body: ["kind": kind, "id": id, "cover": cover])
    }

    /// 改小程序/小游戏：名字、说明、图标（emoji）、入口地址
    func manageSaveMiniApp(id: String, name: String, desc: String,
                           icon: String, group: String, url: String) async throws {
        _ = try await request("POST", "/api/manage/miniapp",
                              body: ["id": id, "name": name, "desc": desc,
                                     "icon": icon, "group": group, "url": url])
    }

    /// 批量删歌（管理页多选以后点删除）
    func manageRemoveMusic(ids: [String]) async throws {
        _ = try await request("POST", "/api/manage/music/remove", body: ["ids": ids])
    }

    /* ---------------------------------------------------------- 系统通知开关（App 管理页） */

    func sysNoticeCfg() async -> (enabled: Bool, types: [String: Bool]) {
        struct R: Decodable { var enabled: Int?; var types: [String: Int]? }
        guard let r: R = try? await get("/api/manage/sysnotice", as: R.self) else {
            return (true, ["login": true, "security": true, "pay": true, "notice": true])
        }
        var t: [String: Bool] = [:]
        (r.types ?? [:]).forEach { t[$0.key] = $0.value != 0 }
        return ((r.enabled ?? 1) != 0, t)
    }

    func saveSysNotice(enabled: Bool, types: [String: Bool]) async throws {
        var t: [String: Int] = [:]
        types.forEach { t[$0.key] = $0.value ? 1 : 0 }
        _ = try await request("POST", "/api/manage/sysnotice", body: ["enabled": enabled ? 1 : 0, "types": t])
    }

    /* ---------------------------------------------------------- 官方号（名字 / 头像） */

    /// 官方号 = 「星言团队」（系统通知号）+ 几个机器人（星联世界 / AI 助手 / 小星 / 在线客服）。
    /// 管理页里像换头像一样换：点一下选张图 → 上传 → 保存。
    struct OfficialAccount: Decodable, Identifiable {
        var key: String
        var name: String
        var avatar: String?
        var desc: String?
        var sys: Bool?
        var id: String { key }
    }

    func officialAccounts() async throws -> [OfficialAccount] {
        struct R: Decodable { var items: [OfficialAccount]? }
        let r: R = try await get("/api/manage/official", as: R.self)
        return r.items ?? []
    }

    /// 改官方号的名字 / 头像（只传要改的那个；两个都不传就等于什么也不改）
    @discardableResult
    func saveOfficial(key: String, name: String? = nil, avatar: String? = nil) async throws -> [OfficialAccount] {
        struct R: Decodable { var items: [OfficialAccount]? }
        var body: [String: Any] = ["key": key]
        if let name = name { body["name"] = name }
        if let avatar = avatar { body["avatar"] = avatar }
        let r: R = try await post("/api/manage/official", body, as: R.self)
        return r.items ?? []
    }

    /// 报一下"我正在听这首"（好友「听一听 → 朋友推荐」那一栏看的就是它）。失败就算了。
    func musicNow(_ t: MusicTrack) async {
        _ = try? await request("POST", "/api/music/now", body: [
            "id": t.id, "title": t.title, "artist": t.artist ?? "",
            "cover": t.cover ?? "", "url": t.url
        ])
    }

    /// 我好友最近在听什么（服务器只回 2 小时内的）
    func friendsNowPlaying() async -> [FriendNowPlaying] {
        guard let p: NowPlayingPayload = try? await get("/api/music/friends", as: NowPlayingPayload.self) else { return [] }
        return p.list ?? []
    }

    /// 给好友的「状态」点赞 / 取消（朋友的状态那一页）
    func statusLike(_ userId: String) async -> (liked: Bool, count: Int)? {
        struct R: Decodable { var liked: Bool?; var count: Int? }
        guard let r: R = try? await post("/api/status/like", ["id": userId], as: R.self) else { return nil }
        return (r.liked ?? false, r.count ?? 0)
    }

    /// 给一首歌点赞 / 取消
    func musicLike(_ id: String) async -> (liked: Bool, count: Int)? {
        struct R: Decodable { var liked: Bool?; var count: Int? }
        guard let r: R = try? await post("/api/music/like", ["id": id], as: R.self) else { return nil }
        return (r.liked ?? false, r.count ?? 0)
    }

    /// 记一次转发（转发音乐卡片时调）
    func musicShareCount(_ id: String) async {
        _ = try? await request("POST", "/api/music/share", body: ["id": id])
    }

    /* ---------------------------------------------------------- 棋牌大厅（桌子） */

    /// 大厅里摆着的桌子
    func gameTables(_ game: String) async -> [GameTable] {
        struct R: Decodable { var tables: [GameTable]? }
        guard let r: R = try? await get("/api/games/tables?game=" + game, as: R.self) else { return [] }
        return r.tables ?? []
    }

    /// 自己开一桌 → (桌号, 我的座位)
    func gameTableCreate(_ game: String) async -> (code: String, seat: Int)? {
        struct T: Decodable { var code: String?; var seats: [GameTableSeat?]? }
        struct R: Decodable { var table: T?; var seat: Int? }
        guard let r: R = try? await post("/api/games/tables/create", ["game": game], as: R.self),
              let code = r.table?.code else { return nil }
        return (code, r.seat ?? 0)
    }

    /// 坐下 → (桌号, 座位, 桌上的人, 开没开)
    func gameTableSit(_ code: String) async -> (seat: Int, players: [String?], started: Bool)? {
        struct T: Decodable { var code: String?; var started: Bool?; var seats: [GameTableSeat?]? }
        struct R: Decodable { var table: T?; var seat: Int?; var started: Bool? }
        guard let r: R = try? await post("/api/games/tables/sit", ["code": code], as: R.self),
              let t = r.table else { return nil }
        let names = (t.seats ?? []).map { $0?.name }
        return (r.seat ?? 0, names, (r.started ?? t.started) ?? false)
    }

    func gameTableLeave(_ code: String) async {
        _ = try? await request("POST", "/api/games/tables/leave", body: ["code": code])
    }

    func gameTableStart(_ code: String) async {
        _ = try? await request("POST", "/api/games/tables/start", body: ["code": code])
    }

    func gameTableMove(_ code: String, _ move: [String: Any]) async {
        _ = try? await request("POST", "/api/games/tables/move", body: ["code": code, "move": move])
    }

    /// 拉别人走的步（轮询）
    func gameTableMoves(_ code: String, since: Int) async -> (n: Int, list: [Any]) {
        struct R: Decodable {
            struct M: Decodable {
                var n: Int?; var seat: Int?
                struct MV: Decodable { var from: Int?; var to: Int? }
                var move: MV?
            }
            var n: Int?; var moves: [M]?
        }
        guard let r: R = try? await get("/api/games/tables/moves?code=\(code)&since=\(since)", as: R.self) else {
            return (since, [])
        }
        let list: [Any] = (r.moves ?? []).map { m in
            ["n": m.n ?? 0, "seat": m.seat ?? 0,
             "move": ["from": m.move?.from ?? 0, "to": m.move?.to ?? 0]]
        }
        return (r.n ?? since, list)
    }

    func branding() async -> BrandInfo? {
        guard let payload: BrandingPayload = try? await get("/api/branding", as: BrandingPayload.self) else { return nil }
        return payload.branding
    }

    /// 便宜的一次探活（离线提示用）：只打 /api/health，不带任何业务数据
    func ping() async {
        _ = try? await request("GET", "/api/health")
    }

    /* 服务器版本（「设置 → 版本更新」用）：拿不到就返回 nil */
    func serverVersion() async -> String? {
        struct VersionPayload: Decodable { var version: String? }
        guard let p: VersionPayload = try? await get("/api/version", as: VersionPayload.self) else { return nil }
        return p.version ?? ""
    }

    /// App 安装包的限时签名链接（要登录才给）：
    /// 安装包直链收口（data/download.json 的 mode=gated）以后，App 内更新就靠这条链接。
    /// 拿不到就返回 nil，调用方退回原来的公开地址（过渡期用）。
    func appDownloadTicket() async -> String? {
        struct P: Decodable { var url: String? }
        guard let p: P = try? await get("/api/app/download", as: P.self) else { return nil }
        let u = (p.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return u.isEmpty ? nil : u
    }

    /// 后台配的「红点提醒」：某个位置 auto（按真实数据）/ on（一直亮）/ off（不显示）
    func badgeConfig() async -> [String: String] {
        guard let payload: BadgesPayload = try? await get("/api/badges", as: BadgesPayload.self) else { return [:] }
        return payload.badges ?? [:]
    }

    /// 服务器上的界面配置（data/ui.json）+ 换过的 UI 图标（data/icons.json）
    func uiConfig() async -> (ui: [String: Any], icons: [String: String]) {
        guard let any = try? await request("GET", "/api/ui"),
              let dict = any as? [String: Any] else { return ([:], [:]) }
        let ui = dict["ui"] as? [String: Any] ?? [:]
        var icons: [String: String] = [:]
        if let raw = dict["icons"] as? [String: Any] {
            for (k, v) in raw where !k.hasPrefix("_") {
                if let s = v as? String, !s.isEmpty { icons[k] = s }
            }
        }
        return (ui, icons)
    }

    /// 把真实量到的尺寸报回服务器（只用来对着参考图校准，不影响使用）
    func reportMeasure(_ items: [[String: Any]]) async {
        _ = try? await request("POST", "/api/measure", body: [
            "screen": Double(L.width),
            "safeTop": Double(L.safeTop),
            "safeBottom": Double(L.safeBottom),
            "menuH": Double(L.menuH),
            "chatRowH": Double(L.rowH),
            "ctRowH": Double(L.ctRowH),
            "items": items
        ])
    }

    func login(username: String, password: String) async throws -> User {
        try await login(username: username, password: password, sliderTicket: "")
    }

    /// 登录。服务器开了「登录滑动验证」时必须带上滑块换来的一次性通行证。
    func login(username: String, password: String, sliderTicket: String) async throws -> User {
        var body: [String: Any] = ["username": username, "password": password]
        if !sliderTicket.isEmpty { body["sliderTicket"] = sliderTicket }
        let payload: LoginPayload = try await post("/api/login", body, as: LoginPayload.self)
        guard let user = payload.user else { throw APIError.message("登录失败") }
        return user
    }

    /* ---------------- 登录滑动验证（拖滑块拼图） ---------------- */

    /* ---------------- 腾讯云 TRTC（音视频通话） ---------------- */

    /// 进房参数：sdkAppId / userId / userSig / roomId（密钥只在服务端）
    struct TRTCSig: Decodable {
        var sdkAppId: Int
        var userId: String
        var userSig: String
        var roomId: Int
        var roomStr: String?
        var expire: Int?
    }

    /// 取一张 TRTC 进房票。room 用「这次通话的 callId」，两边算出来的房间号一致。
    /// media 只是给服务端看的开关：服务端把 data/trtc.json 的 voiceEnabled 设成 false，
    /// 语音这条就会拿到失败、自动继续用自建转发通道（不用重装 App 就能一键退回）。
    func trtcSig(room: String, media: String = "video") async throws -> TRTCSig {
        try await get("/api/trtc/sig?room=" + (room.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? room)
                      + "&media=" + media,
                      as: TRTCSig.self)
    }

    /// 服务端出的一道题：缺口在哪、坐标系多大、背景用什么种子画
    struct SliderChallenge: Decodable {
        var id: String
        var width: Double
        var height: Double
        var piece: Double
        var targetX: Double
        var targetY: Double
        var tolerance: Double?
        var seed: Int?
        var expiresIn: Int?
    }

    private struct SliderTicketPayload: Decodable { var ticket: String?; var expiresIn: Int? }

    /// 领题（同一个 IP 10 分钟最多 40 次）
    func sliderChallenge() async throws -> SliderChallenge {
        try await get("/api/slider", as: SliderChallenge.self)
    }

    /// 交卷：位置对了，服务端给一张一次性通行证（3 分钟有效、用掉即废）
    func verifySlider(id: String, x: Double, y: Double) async throws -> String {
        let payload: SliderTicketPayload = try await post("/api/slider/verify",
                                                          ["id": id, "x": x, "y": y],
                                                          as: SliderTicketPayload.self)
        guard let t = payload.ticket, !t.isEmpty else { throw APIError.message("滑动验证失败") }
        return t
    }

    /// 账号被禁用后的「身份证自助解封」：服务器校验 18 位身份证（含校验位），
    /// 通过就解封并把登录态直接发下来，所以调完这个就等于登录成功了。
    @discardableResult
    func unban(username: String, password: String, idCard: String) async throws -> User {
        let payload: LoginPayload = try await post("/api/unban",
                                                   ["username": username, "password": password, "idCard": idCard],
                                                   as: LoginPayload.self)
        guard let user = payload.user else { throw APIError.message("解封失败") }
        return user
    }

    /* ============================================================ 冻结 / 解冻（对齐微信「安全中心」）
       2026-10-12 用户：「把微信的真实封号和解冻、可以自己冻结做出来对齐」。
       服务器侧：GET /api/account/state（查状态）、POST /api/me/freeze（自己冻）、
                POST /api/account/unfreeze（自助解冻，解完直接发登录态）、
                POST /api/ops/account（管理侧冻结/解冻/封禁/解封）。 */

    struct AccountStatePayload: Decodable {
        var exists: Bool?
        var banned: Bool?
        var frozen: Bool?
        var reason: String?
    }
    struct FrozenPayload: Decodable { var frozen: Bool?; var reason: String?; var unfrozen: Bool? }

    /// 查某个账号的状态（登录页用它决定提示「被冻结」还是「被禁用」）
    func accountState(_ username: String) async -> (exists: Bool, banned: Bool, frozen: Bool, reason: String) {
        let q = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let p: AccountStatePayload = try? await get("/api/account/state?u=" + q, as: AccountStatePayload.self)
        else { return (false, false, false, "") }
        return (p.exists ?? false, p.banned ?? false, p.frozen ?? false, p.reason ?? "")
    }

    /// 自己冻结账号（设过登录密码的要带上密码）；返回 nil = 成功，否则是错误文案
    func freezeSelf(password: String) async -> String? {
        do {
            _ = try await post("/api/me/freeze", ["password": password], as: FrozenPayload.self)
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? "冻结失败"
        }
    }

    /// 自助解冻（不需要登录态）：账号 + 密码 +（可选）实名身份证号；成功直接拿到登录态
    @discardableResult
    func unfreeze(username: String, password: String, idCard: String = "") async throws -> User {
        var b: [String: Any] = ["username": username, "password": password]
        if !idCard.isEmpty { b["idCard"] = idCard }
        let payload: LoginPayload = try await post("/api/account/unfreeze", b, as: LoginPayload.self)
        guard let user = payload.user else { throw APIError.message("解冻失败") }
        return user
    }

    /// 管理侧：冻结 / 解冻 / 封禁 / 解封（action = freeze / unfreeze / ban / unban）
    @discardableResult
    func opsAccount(userId: String, action: String, reason: String = "") async -> Bool {
        struct P: Decodable { var user: U?; struct U: Decodable { var id: String? } }
        return (try? await post("/api/ops/account",
                                ["userId": userId, "action": action, "reason": reason], as: P.self)) != nil
    }

    /* ============================================================ 漂流瓶（摇一摇改成漂流瓶）
       POST /api/bottle/throw {text} / POST /api/bottle/pick / GET /api/bottle/count */

    /// 一个瓶子
    struct APIBottle: Decodable, Identifiable, Hashable {
        var id: String
        var text: String
        var fromName: String?
        var at: String?
    }
    private struct BottleCountPayload: Decodable { var total: Int? }
    private struct BottlePickPayload: Decodable {
        var bottle: APIBottle?
        var empty: Bool?
        var total: Int?
    }

    func bottleCount() async -> Int {
        do {
            let p = try await get("/api/bottle/count", as: BottleCountPayload.self)
            return p.total ?? 0
        } catch {
            /* ⚠ 2026-10-13 用户报「漂流瓶没有东西」：以前这里 `try?` 把错误吃掉了，
               页面上只看到「海里漂着 0 个瓶子」，根本不知道是网络、还是服务器没这个口。
               现在把失败原因写进打点（服务器 data/client-errors.jsonl 能看到）。 */
            AppLog.error("漂流瓶", "查数量失败：" + ((error as? APIError)?.errorDescription ?? "\(error)"))
            return 0
        }
    }

    @discardableResult
    func throwBottle(text: String) async -> Bool {
        do {
            _ = try await post("/api/bottle/throw", ["text": text], as: BottleCountPayload.self)
            return true
        } catch {
            AppLog.error("漂流瓶", "扔失败：" + ((error as? APIError)?.errorDescription ?? "\(error)"))
            return false
        }
    }

    func pickBottle() async -> (bottle: APIBottle?, total: Int) {
        do {
            let p = try await post("/api/bottle/pick", [:], as: BottlePickPayload.self)
            return (p.bottle, p.total ?? 0)
        } catch {
            AppLog.error("漂流瓶", "捞失败：" + ((error as? APIError)?.errorDescription ?? "\(error)"))
            return (nil, 0)
        }
    }

    /* ============================================================ 阅后即焚
       POST /api/chats/<id>/burn {on}       → 开关
       POST /api/chats/<id>/burn-sweep      → 读过的就销毁（返回这次真删掉的 id） */

    private struct BurnPayload: Decodable { var burn: Bool? }
    private struct BurnSweepPayload: Decodable { var ids: [String]? }

    /// 开/关某个会话的阅后即焚；返回服务器确认后的状态
    func setChatBurn(chatId: String, on: Bool) async -> Bool {
        let p: BurnPayload? = try? await post("/api/chats/\(chatId)/burn", ["on": on], as: BurnPayload.self)
        return p?.burn ?? on
    }

    /// 进聊天页 / 收到新消息时扫一遍：别人发给我、我看过满 8 秒的消息会被销毁
    func burnSweep(chatId: String) async -> [String] {
        let p: BurnSweepPayload? = try? await post("/api/chats/\(chatId)/burn-sweep", [:],
                                                   as: BurnSweepPayload.self)
        return p?.ids ?? []
    }

    /// 本地没接短信通道，服务器会直接把验证码给回来
    func phoneCode(phone: String) async throws -> String? {
        let payload: PhoneCodePayload = try await post("/api/login/phone-code",
                                                       ["phone": phone],
                                                       as: PhoneCodePayload.self)
        return payload.devCode
    }

    /// 注册用的图形验证码（服务器给的是 SVG，App 里用 CaptchaView 画出来）
    func captcha() async throws -> (id: String, svg: String) {
        let payload: CaptchaPayload = try await get("/api/captcha", as: CaptchaPayload.self)
        return (payload.id ?? "", payload.svg ?? "")
    }

    /// 注册新账号（注册完成后由调用方再去登录一次）
    func register(username: String, nickname: String, password: String, captchaId: String, captcha: String) async throws -> User {
        let payload: LoginPayload = try await post("/api/register", [
            "username": username,
            "nickname": nickname,
            "password": password,
            "captchaId": captchaId,
            "captcha": captcha
        ], as: LoginPayload.self)
        guard let user = payload.user else { throw APIError.message("注册失败") }
        return user
    }

    /* ---------------- 设备确认登录（就是「微信登录」那个核心按钮）----------------
       这台设备出一个 6 位数字，在已经登录的设备上确认，这台就登上了。 */
    func pairStart(device: String = "") async throws -> (code: String, expiresIn: Int) {
        var body: [String: Any] = [:]
        if !device.isEmpty { body["device"] = device }
        /* 带上「这台手机上次登录的账号」：服务端就能直接给那台**已登录的手机**推一条
           「登录确认」（不用手输数字）。没登录过就没有这个提示，靠对方扫二维码确认。 */
        if let last = AccountStore.load().first?.username, !last.isEmpty {
            body["username"] = last
        }
        let p: PairStartPayload = try await post("/api/pair/start", body, as: PairStartPayload.self)
        return (p.code ?? "", p.expiresIn ?? 180)
    }

    /// 确认方先看一眼：这是哪台设备在请求登录（微信的确认页会写清楚设备名和时间）
    func pairInfo(code: String) async -> (device: String, at: String)? {
        struct Payload: Decodable { var status: String?; var device: String?; var at: String? }
        guard let p: Payload = try? await get("/api/pair/info?code=\(code)", as: Payload.self),
              (p.status ?? "") == "pending" else { return nil }
        return (p.device ?? "", p.at ?? "")
    }

    /// 轮询：pending（还没确认）/ approved（确认了，带回登录令牌）/ expired
    func pairStatus(code: String) async throws -> (status: String, user: User?, token: String?) {
        let p: PairStatusPayload = try await get("/api/pair/status?code=\(code)", as: PairStatusPayload.self)
        return (p.status ?? "pending", p.user, p.token)
    }

    /// 已登录的这台设备去确认别人（网页版点「微信授权登录」出的那个数字）
    @discardableResult
    func pairApprove(code: String) async -> String? {
        do {
            struct ApprovePayload: Decodable { var approved: Bool? }
            let _: ApprovePayload = try await post("/api/pair/approve", ["code": code], as: ApprovePayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "确认失败" }
    }

    func loginPhone(phone: String, code: String) async throws -> User {
        let payload: LoginPayload = try await post("/api/login/phone",
                                                   ["phone": phone, "code": code],
                                                   as: LoginPayload.self)
        guard let user = payload.user else { throw APIError.message("登录失败") }
        return user
    }

    func session() async throws -> (ok: Bool, user: User?) {
        let payload: SessionPayload = try await get("/api/session", as: SessionPayload.self)
        return (payload.authenticated ?? false, payload.user)
    }

    func logout() async {
        _ = try? await request("POST", "/api/logout", body: [:])
        clearToken()
    }

    func me() async throws -> User? {
        let payload: MePayload = try await get("/api/me", as: MePayload.self)
        return payload.user
    }

    /// 个人名片要的完整资料（带 relation / online / phone / momentCount）
    func user(id: String) async throws -> User {
        let payload: UserPayload = try await get("/api/users/\(id)", as: UserPayload.self)
        guard let user = payload.user else { throw APIError.message("用户不存在") }
        return user
    }

    /* ---------------------------------------------------------- 附近的人 */

    /// 上报自己的位置（进「附近的人」页时调一次）；visible=false 就是隐身，不上榜
    func nearbyReport(lat: Double, lng: Double, visible: Bool = true) async throws {
        _ = try await request("POST", "/api/nearby", body: [
            "lat": lat, "lng": lng, "visible": visible
        ])
    }

    /// 附近的人名单（按距离排）
    func nearby(lat: Double?, lng: Double?, gender: String = "all", maxKm: Double = 5)
        async throws -> (people: [NearbyPerson], wider: Int, maxKm: Double) {
        var path = "/api/nearby?gender=\(gender)&maxKm=\(maxKm)"
        if let lat = lat, let lng = lng { path += "&lat=\(lat)&lng=\(lng)" }
        let payload: NearbyPayload = try await get(path, as: NearbyPayload.self)
        return (payload.people, payload.wider ?? 0, payload.maxKm ?? maxKm)
    }

    /// 打招呼：给对方发一条消息（会话就出来了）
    func nearbyHello(userId: String, text: String) async throws -> String {
        let payload: NearbyHelloPayload = try await post("/api/nearby/hello",
                                                         ["userId": userId, "text": text],
                                                         as: NearbyHelloPayload.self)
        return payload.chatId ?? ""
    }

    /// 清除自己的位置（从附近的人里消失，和微信的「清除位置信息并退出」一样）
    func nearbyClear() async throws {
        _ = try await request("DELETE", "/api/nearby")
    }

    /* ---------------------------------------------------------- 直播专场 */

    func liveRooms() async throws -> [LiveRoom] {
        let p: LivePayload = try await get("/api/live", as: LivePayload.self)
        return p.rooms
    }
    func liveJoin(_ id: String) async throws -> Int {
        let p: LiveJoinPayload = try await post("/api/live/\(id)/join", [:], as: LiveJoinPayload.self)
        return p.watching ?? 0
    }
    func liveLeave(_ id: String) async {
        _ = try? await request("POST", "/api/live/\(id)/leave", body: [:])
    }
    func liveDanmaku(_ id: String, text: String) async throws {
        _ = try await request("POST", "/api/live/\(id)/danmaku", body: ["text": text])
    }
    func liveLike(_ id: String) async throws -> Int {
        let p: LiveLikePayload = try await post("/api/live/\(id)/like", [:], as: LiveLikePayload.self)
        return p.likes ?? 0
    }

    /* ---------------------------------------------------------- 游戏页 */

    func games() async throws -> [MiniGame] {
        let p: GamesPayload = try await get("/api/games", as: GamesPayload.self)
        return p.items
    }

    /* ---------------------------------------------------------- 视频号 */

    func feedItems() async throws -> [FeedItem] {
        let p: FeedPayload = try await get("/api/feed", as: FeedPayload.self)
        return p.items
    }
    /// 只看自己发布的作品（「我 → 作品」那一页用）
    func myFeedItems() async throws -> [FeedItem] {
        let p: FeedPayload = try await get("/api/feed?mine=1", as: FeedPayload.self)
        return p.items
    }
    /// 列表 + 后台配的样式和开关
    /// tab: recommend 推荐（抖音那套）/ follow 关注 / friends 朋友
    func feed(tab: String = "recommend") async throws -> (items: [FeedItem], style: FeedStyle, flags: FeedFlags) {
        let p: FeedPayload = try await get("/api/feed?tab=\(tab)", as: FeedPayload.self)
        return (p.items, p.style ?? FeedStyle(), p.flags ?? FeedFlags())
    }

    /* ---------------- 位置搜索（走高德） ----------------
       后台配了高德 Key 就用高德的 POI（国内比苹果地图准很多），没配时服务端返回 503，
       调用方自己退回系统地图搜索。 */
    struct GeoPlace: Decodable {
        var name: String?
        var addr: String?
        var lat: Double?
        var lng: Double?
    }
    private struct GeoSearchPayload: Decodable {
        var source: String?
        var places: [GeoPlace]?
    }
    func geoSearch(q: String, lat: Double, lng: Double) async throws -> [GeoPlace] {
        let q2 = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let p: GeoSearchPayload = try await get("/api/geo/search?q=\(q2)&lat=\(lat)&lng=\(lng)",
                                                as: GeoSearchPayload.self)
        return p.places ?? []
    }
    func feedLike(_ id: String) async throws -> (liked: Bool, likes: Int) {
        /* 注意：服务器这条是 POST /api/feed/like，body 里带 id（不是路径参数） */
        let p: FeedLikePayload = try await post("/api/feed/like", ["id": id], as: FeedLikePayload.self)
        return (p.liked ?? false, p.likes ?? 0)
    }

    /// 视频号「关注 / 取消关注」（和好友关系分开，微信视频号就是这个逻辑）
    func feedFollow(userId: String, follow: Bool) async -> Bool {
        struct P: Decodable { var following: Bool?; var count: Int? }
        let p: P? = try? await post("/api/feed/follow", ["userId": userId, "follow": follow], as: P.self)
        return p?.following ?? false
    }
    func feedComment(_ id: String, text: String) async throws -> Int {
        let p: FeedCommentPayload = try await post("/api/feed/comment", ["id": id, "text": text],
                                                   as: FeedCommentPayload.self)
        return p.comments ?? 0
    }
    /// 读某条视频的评论列表
    func feedComments(_ id: String) async throws -> [FeedCommentItem] {
        let p: FeedCommentsPayload = try await get("/api/feed/comments?id=\(id)", as: FeedCommentsPayload.self)
        return p.comments ?? []
    }
    /// 取一整套短剧的全部集数（「选集」面板用）
    func feedSeries(_ id: String) async throws -> (name: String, items: [FeedItem]) {
        let p: FeedSeriesPayload = try await get("/api/feed/series?id=\(id)", as: FeedSeriesPayload.self)
        return (p.name ?? "", p.items ?? [])
    }
    /// 收藏 / 取消收藏一条视频
    func feedFavorite(_ id: String) async throws -> (favorited: Bool, favorites: Int) {
        let p: FeedFavoritePayload = try await post("/api/feed/favorite", ["id": id], as: FeedFavoritePayload.self)
        return (p.favorited ?? false, p.favorites ?? 0)
    }
    func feedPublish(video: String, desc: String, music: String) async throws -> String {
        let p: FeedPublishPayload = try await post("/api/feed/publish",
                                                   ["video": video, "desc": desc, "music": music],
                                                   as: FeedPublishPayload.self)
        return p.id ?? ""
    }
    func feedDelete(_ id: String) async {
        _ = try? await request("DELETE", "/api/feed/\(id)")
    }
    /// 剪水印：把带水印的那条边裁掉，返回新视频地址（服务端 ffmpeg 处理）
    func feedTrim(_ url: String, top: Double, bottom: Double, left: Double, right: Double) async throws -> String {
        let p: FeedTrimPayload = try await post("/api/feed/trim",
                                                ["url": url, "top": top, "bottom": bottom,
                                                 "left": left, "right": right, "fill": true],
                                                as: FeedTrimPayload.self)
        return p.url ?? url
    }

    /* ---------------------------------------------------------- 摇一摇 */

    /// 摇一下：把自己「正在摇」报上去，服务器把同时摇的人配给我
    func shake(lat: Double?, lng: Double?) async throws -> ShakeResult {
        var body: [String: Any] = [:]
        if let lat = lat, let lng = lng { body["lat"] = lat; body["lng"] = lng }
        return try await post("/api/shake", body, as: ShakeResult.self)
    }

    /// 通话诊断：连不上时把 ICE 状态报回服务器（写进 call-trace.log）
    func callDiag(_ text: String) async {
        _ = try? await request("POST", "/api/call-diag", body: ["text": text])
    }

    func chats() async throws -> [Chat] {
        let payload: ChatsPayload = try await get("/api/chats", as: ChatsPayload.self)
        return payload.chats
    }

    /* ---------------- 登录后同步最近的聊天记录（微信那句「登录后同步最近的聊天记录」） ----------------
       服务端支持一次把最近 N 个会话 + 每个会话最近 M 条消息带回来（/api/chats?withMessages=1），
       同步下来的消息先铺在界面上（进会话不用等网络），随后再拉最新的。 */
    struct SyncChat: Decodable {
        var id: String
        var title: String?
        var messages: [Message]?
    }
    private struct SyncChatsPayload: Decodable {
        var chats: [Chat]
        var sync: Sync?
        struct Sync: Decodable {
            var chats: [SyncChat]?
            var syncedAt: String?
        }
    }

    func chatsWithRecentMessages(chats: Int = 10, limit: Int = 30) async throws -> (chats: [Chat], synced: [SyncChat], syncedAt: String) {
        let n = max(1, min(30, chats))
        let m = max(5, min(100, limit))
        let p: SyncChatsPayload = try await get("/api/chats?withMessages=1&syncChats=\(n)&syncLimit=\(m)",
                                                as: SyncChatsPayload.self)
        return (p.chats, p.sync?.chats ?? [], p.sync?.syncedAt ?? "")
    }

    /// 按「微信号 / 手机号」精确找人（转账页填收款账号用）
    func findUserByAccount(_ q: String) async throws -> User? {
        let payload: UsersPayload = try await get("/api/users?q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)", as: UsersPayload.self)
        return payload.users.first
    }

    /// 搜人（微信「添加朋友」那种）：返回列表，带 relation 字段（friend / requested / incoming / none）
    func searchUsers(_ q: String) async throws -> [User] {
        let payload: UsersPayload = try await get("/api/users?q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)", as: UsersPayload.self)
        return payload.users
    }

    /// 发好友申请时可以带一句验证消息
    func addFriend(username: String, note: String) async throws {
        var body: [String: Any] = ["username": username]
        if !note.isEmpty { body["message"] = note }
        _ = try await request("POST", "/api/friends/request", body: body)
    }

    /// 搜到的人没有星言号时用 userId 发申请（同样能带验证消息）
    func addFriend(userId: String, note: String = "") async throws {
        var body: [String: Any] = ["userId": userId]
        if !note.isEmpty { body["message"] = note }
        _ = try await request("POST", "/api/friends/request", body: body)
    }

    /* ---------------------------------------------------------- 朋友资料（微信「设置备注和标签」） */

    struct FriendMeta: Decodable {
        var remark: String?
        var tags: [String]?
        var star: Bool?
        var block: Bool?
        /// 我不看他（她）的朋友圈
        var noMoments: Bool?
        /// 他不能看我的朋友圈
        var hideMyMoments: Bool?
        var chatOnly: Bool?
        /// 好友添加时间 / 来源（我加的 / 他加的我）/ 他有没有拉黑我
        var addedAt: String?
        var source: String?
        var blockedMe: Bool?
    }

private struct FriendMetaPayload: Decodable {
    var meta: FriendMeta?
    var addedAt: String?
    var source: String?
    var blockedMe: Bool?
}

/// 通讯录「★ 星标朋友」那一组：服务端只回 id（资料从已加载的联系人里取）
private struct StarredPayload: Decodable {
    var ids: [String]?
    var list: [Row]?
    struct Row: Decodable {
        var id: String?
        var name: String?
        var avatar: String?
    }
}

    func friendMeta(userId: String) async throws -> FriendMeta {
        let p: FriendMetaPayload = try await get("/api/friends/meta?userId=\(userId)", as: FriendMetaPayload.self)
        var m = p.meta ?? FriendMeta()
        if m.addedAt == nil { m.addedAt = p.addedAt }
        if m.source == nil { m.source = p.source }
        if m.blockedMe == nil { m.blockedMe = p.blockedMe }
        return m
    }

    /// 我设的「星标朋友」都是谁（通讯录顶上 ★ 那一组用）——返回 id 列表
    func starredFriends() async throws -> [String] {
        let p: StarredPayload = try await get("/api/friends/starred", as: StarredPayload.self)
        return p.ids ?? []
    }

    /// 改备注名 / 标签 / 星标 / 朋友权限 / 拉黑 —— 只传要改的那几项
    @discardableResult
    func setFriendMeta(userId: String, remark: String? = nil, tags: [String]? = nil,
                       star: Bool? = nil, block: Bool? = nil,
                       noMoments: Bool? = nil, hideMyMoments: Bool? = nil) async -> Bool {
        var body: [String: Any] = ["userId": userId]
        if let v = remark { body["remark"] = v }
        if let v = tags { body["tags"] = v }
        if let v = star { body["star"] = v }
        if let v = block { body["block"] = v }
        if let v = noMoments { body["noMoments"] = v }
        if let v = hideMyMoments { body["hideMyMoments"] = v }
        do { _ = try await request("POST", "/api/friends/meta", body: body); return true }
        catch { return false }
    }

    /// 删除好友（只动我这边，对方通讯录不受影响 —— 微信就是这样）
    func removeFriend(userId: String) async -> String? {
        do {
            _ = try await request("POST", "/api/friends/remove", body: ["userId": userId])
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? "删除失败"
        }
    }

    /* ---------------------------------------------------------- 账号与安全（微信那套） */

    /* ---------------------------------------------------------- 共享实时位置 */

    /* ---------------------------------------------------------- 零钱：银行卡 / 充值 / 提现 */

    struct WalletBankCard: Decodable, Identifiable, Hashable {
        var id: String
        var bank: String?
        var tail: String?
        var holder: String?
        var isDefault: Bool?
        var addedAt: String?
        var label: String { (bank ?? "银行卡") + "（" + (tail ?? "****") + "）" }
    }
    private struct BanksPayload: Decodable { var banks: [WalletBankCard]? }
    private struct BankPayload: Decodable { var bank: WalletBankCard?; var banks: [WalletBankCard]? }

    func walletBanks() async throws -> [WalletBankCard] {
        let p: BanksPayload = try await get("/api/wallet/banks", as: BanksPayload.self)
        return p.banks ?? []
    }

    func addBank(bank: String, cardNo: String, holder: String) async throws -> [WalletBankCard] {
        let p: BankPayload = try await post("/api/wallet/banks",
                                            ["bank": bank, "cardNo": cardNo, "holder": holder],
                                            as: BankPayload.self)
        return p.banks ?? []
    }

    func removeBank(id: String) async {
        _ = try? await request("POST", "/api/wallet/banks/remove", body: ["id": id])
    }

    struct MoneyResult: Decodable {
        var balance: Double?
        var fee: Double?
        var bankText: String?
        var expect: String?
        var status: String?
    }

    /// 充值：银行卡 → 零钱
    func walletRecharge(amount: Double, bankId: String) async throws -> MoneyResult {
        try await post("/api/wallet/recharge", ["amount": amount, "bankId": bankId], as: MoneyResult.self)
    }

    /// 提现：零钱 → 银行卡（要支付密码，或已通过面容）
    func walletWithdraw(amount: Double, bankId: String, password: String, face: Bool) async throws -> MoneyResult {
        try await post("/api/wallet/withdraw",
                       ["amount": amount, "bankId": bankId, "password": password, "face": face],
                       as: MoneyResult.self)
    }

    struct WalletOp: Decodable, Identifiable, Hashable {
        var id: String
        var kind: String?
        var amount: Double?
        var fee: Double?
        var bankText: String?
        var status: String?
        var createdAt: String?
    }
    private struct OpsPayload: Decodable { var ops: [WalletOp]? }

    func walletOps() async throws -> [WalletOp] {
        let p: OpsPayload = try await get("/api/wallet/withdraws", as: OpsPayload.self)
        return p.ops ?? []
    }

    /* ---------------------------------------------------------- 存储空间 */
    struct StorageChat: Decodable, Identifiable {
        var chatId: String
        var title: String
        var avatar: String?
        var messages: Int
        var bytes: Int
        var id: String { chatId }
    }
    struct StorageInfo: Decodable {
        struct Kinds: Decodable {
            var image: Int
            var video: Int
            var file: Int
            var audio: Int
        }
        var total: Int
        var chats: [StorageChat]
        var kinds: Kinds
        var uploads: Int
    }
    func storage() async throws -> StorageInfo {
        try await get("/api/storage", as: StorageInfo.self)
    }

    /* ------------------------------------------------ 红包（微信那套） ----------------------------------
       拼手气 / 普通、群红包、每人限领一次、24 小时没抢完退回发红包的人。
       卡片上要的信息、拆红包、详情、红包记录都在下面这几个调用里。 */
    struct RedPacketRaw: Decodable {
        var id: String
        var total: Double?
        var count: Int?
        var claimedCount: Int?
        var claimedIds: [String]?
        var type: String?
        var note: String?
        var status: String?
        var expired: Bool?
        var fromId: String?
        var fromName: String?
        var expiresAt: Double?
        var refundAmount: Double?
        /* 封面（发红包时挑的那张，卡片和拆红包页按它画） */
        var coverId: String?
        var coverName: String?
        var cover: String?
        var coverThumb: String?
        var coverColor: String?
        /* 详情接口额外给的 */
        var fromAvatar: String?
        var claimedTotal: Double?
        var leftAmount: Double?
        var leftCount: Int?
        var bestUserId: String?
        var bestAmount: Double?
        var claims: [RedPacketClaimRaw]?
    }
    struct RedPacketClaimRaw: Decodable {
        var userId: String
        var name: String?
        var avatar: String?
        var amount: Double
        var at: String?
        var fromId: String?
        var fromName: String?
    }
    struct RedPacketSendResult: Decodable {
        var balance: Double
        var amount: Double?
        var count: Int?
        var type: String?
        var redpacket: RedPacketRaw
    }
    struct RedPacketClaimResult: Decodable {
        var balance: Double
        var amount: Double
        var redpacket: RedPacketRaw
        var leftCount: Int?
    }
    struct RedPacketDetailResult: Decodable {
        var redpacket: RedPacketRaw
    }
    struct RedPacketRecord: Decodable, Identifiable {
        var id: String
        var chatId: String?
        var direction: String?
        var total: Double?
        var count: Int?
        var type: String?
        var note: String?
        var status: String?
        var expired: Bool?
        var claimedCount: Int?
        var fromName: String?
        var fromAvatar: String?
        var mineAmount: Double?
        var createdAt: String?
        var expiresAt: Double?
    }
    struct RedPacketMineResult: Decodable {
        var redpackets: [RedPacketRecord]?
    }
    /* 红包封面（后台配的封面库） */
    struct RedPacketCoverRaw: Decodable, Identifiable {
        var id: String
        var name: String?
        var image: String?
        var thumb: String?
        var color: String?
    }
    struct RedPacketCoversResult: Decodable {
        var covers: [RedPacketCoverRaw]?
        var defaultId: String?
        var mine: String?
    }
    struct RedPacketCoverPick: Decodable {
        var coverId: String?
        var name: String?
    }
    /* 常见问题（内容来自后台客服中心里配的问答） */
    struct FAQPayload: Decodable {
        var title: String?
        var searchHint: String?
        var categories: [SupportCategory]?
        var hot: [SupportItem]?
    }
    /* 账户升级服务：等级 / 额度 / 还差哪一步 */
    struct WalletLevelStep: Decodable {
        var key: String?
        var name: String?
        var done: Bool?
        var hint: String?
    }
    struct WalletLevelRow: Decodable {
        var level: Int?
        var name: String?
        var single: Double?
        var day: Double?
        var current: Bool?
        var done: Bool?
    }
    struct WalletLevel: Decodable {
        var level: Int?
        var levelName: String?
        var tip: String?
        var single: Double?
        var day: Double?
        var receive: Double?
        var usedToday: Double?
        var leftToday: Double?
        var realName: Bool?
        var bankCount: Int?
        var upgradedAt: String?
        var levels: [WalletLevelRow]?
        var steps: [WalletLevelStep]?
    }
    struct WalletUpgradeResult: Decodable {
        var level: Int?
        var levelName: String?
        var single: Double?
        var day: Double?
    }
    /* 经营账户（收款记录 / 经营设置 / 提现到零钱 / 开票信息） */
    struct BizRecordRaw: Decodable, Identifiable {
        var id: String
        var kind: String?
        var amount: Double?
        var fromName: String?
        var fromId: String?
        var method: String?
        var note: String?
        var orderNo: String?
        var status: String?
        var settled: Bool?
        var createdAt: String?
    }
    struct BizInvoiceRaw: Decodable, Identifiable {
        var id: String
        var amount: Double?
        var status: String?
        var title: String?
        var taxNo: String?
        var kind: String?
        var note: String?
        var createdAt: String?
        var handledAt: String?
    }
    struct BizSettingsRaw: Decodable {
        var arrival: String?
        var notify: Bool?
        var autoWithdraw: Bool?
        var settle: String?
        var feeRate: Double?
        var shopName: String?
        var remark: String?
    }
    struct BizInvoiceInfoRaw: Decodable {
        var title: String?
        var taxNo: String?
        var address: String?
        var phone: String?
        var bankName: String?
        var bankAccount: String?
    }
    struct BizTotals: Decodable {
        var today: Double?
        var month: Double?
        var all: Double?
        var count: Int?
        var withdrawn: Double?
    }
    struct BizPayload: Decodable {
        var enabled: Bool?
        var balance: Double?
        var settings: BizSettingsRaw?
        var invoice: BizInvoiceInfoRaw?
        var records: [BizRecordRaw]?
        var invoices: [BizInvoiceRaw]?
        var totals: BizTotals?
        var invoiceReady: Bool?
    }
    struct BizWithdrawResult: Decodable {
        var balance: Double?
        var bizBalance: Double?
        var amount: Double?
    }
    /* 身份信息（钱包 → 身份信息） */
    struct IdentityInfo: Decodable {
        var verified: Bool?
        var realName: String?
        var idMask: String?
        var verifiedAt: String?
        var idValid: String?
        var occupation: String?
        var address: String?
        var level: Int?
        var levelName: String?
        var bankCount: Int?
    }
    /* 支付设置（钱包 → 支付设置） */
    struct AutoDebit: Decodable, Identifiable {
        var id: String
        var name: String?
        var amount: Double?
        var cycle: String?
        var createdAt: String?
    }
    struct PaySettings: Decodable {
        var hasPayPassword: Bool?
        var noPin: Bool?
        var noPinLimit: Double?
        var payMethod: String?
        var autoDebits: [AutoDebit]?
        var payPasswordUpdatedAt: String?
    }
    struct SimpleOK: Decodable { var saved: Bool? }

    func identity() async throws -> IdentityInfo {
        try await get("/api/me/identity", as: IdentityInfo.self)
    }
    func saveIdentity(idValid: String, occupation: String, address: String) async {
        let _: SimpleOK? = try? await post("/api/me/identity",
            ["idValid": idValid, "occupation": occupation, "address": address], as: SimpleOK.self)
    }
    func paySettings() async throws -> PaySettings {
        try await get("/api/me/paysettings", as: PaySettings.self)
    }

    /* 支付分（钱包 → 支付分）：分数 + 三个维度 + 免押服务 + 分值变化 */
    struct PayScoreDim: Decodable, Identifiable {
        var key: String
        var name: String
        var value: Double
        /// 这一项占多少权重（满分，例如身份特质 25 分）—— CHRIS_PAYSCORE_V2 起下发
        var weight: Double?
        /// 这一项实际拿到多少分（points / max）
        var points: Double?
        var max: Double?
        var desc: String?
        var tip: String?
        var id: String { key }
    }
    struct PayScoreService: Decodable, Identifiable {
        var id: String
        var name: String
        var desc: String?
        var need: Double?
        var ok: Bool?
        var gap: Double?
    }
    struct PayScoreHistory: Decodable, Identifiable {
        var at: String
        var text: String
        var delta: Double
        var id: String { at + text + String(delta) }
    }
    struct PayScore: Decodable {
        var score: Double
        var level: String
        var min: Double
        var max: Double
        /// 算分公式（人话，给用户看的规则） + 这次算出来的时间
        var formula: String?
        var updatedAt: String?
        var dims: [PayScoreDim]?
        var services: [PayScoreService]?
        var history: [PayScoreHistory]?
        var note: String?
    }
    func payScore() async throws -> PayScore {
        try await get("/api/me/payscore", as: PayScore.self)
    }

    /* 青少年模式（设置 → 青少年模式）：开关要 4 位密码，开了按勾选限制功能 */
    struct TeenStatus: Decodable {
        var enabled: Bool?
        var hasPin: Bool?
        var scopes: [String: Int]?
        var guardianPhone: String?
        var setAt: String?
    }
    private struct TeenPayload: Decodable { var teen: TeenStatus? }

    func teen() async throws -> TeenStatus {
        let p: TeenPayload = try await get("/api/me/teen", as: TeenPayload.self)
        return p.teen ?? TeenStatus()
    }
    func teenSetup(pin: String) async throws -> TeenStatus {
        let p: TeenPayload = try await post("/api/me/teen/setup", ["pin": pin], as: TeenPayload.self)
        return p.teen ?? TeenStatus()
    }
    func teenSet(pin: String, enabled: Bool?, scopes: [String: Int]?, guardianPhone: String?) async throws -> TeenStatus {
        var body: [String: Any] = ["pin": pin]
        if let e = enabled { body["enabled"] = e }
        if let s = scopes { body["scopes"] = s }
        if let g = guardianPhone { body["guardianPhone"] = g }
        let p: TeenPayload = try await post("/api/me/teen/set", body, as: TeenPayload.self)
        return p.teen ?? TeenStatus()
    }
    func savePaySettings(noPin: Bool, noPinLimit: Double, payMethod: String) async {
        let _: SimpleOK? = try? await post("/api/me/paysettings",
            ["noPin": noPin, "noPinLimit": noPinLimit, "payMethod": payMethod], as: SimpleOK.self)
    }
    func cancelAutoDebit(_ id: String) async {
        let _: SimpleOK? = try? await post("/api/me/paysettings", ["cancelAutoDebit": id], as: SimpleOK.self)
    }

    /* 我的收藏（微信「我 → 收藏」那一页） */
    struct FavoriteItem: Decodable, Identifiable {
        var id: String
        var kind: String?
        var content: String?
        var createdAt: String?
        var chatId: String?
        var fromName: String?
    }
    private struct FavoritesPayload: Decodable { var favorites: [FavoriteItem]? }

    func favorites() async -> [FavoriteItem] {
        let p: FavoritesPayload? = try? await get("/api/favorites", as: FavoritesPayload.self)
        return p?.favorites ?? []
    }

    func deleteFavorite(_ id: String) async {
        _ = try? await request("DELETE", "/api/favorites/" + id)
    }

    /* ---------------- 我自己的「文件」页（发文件时挑文件用，不走苹果的文件 App） ----------------
       服务端把这个账号在各会话里发过/收到过的文件按时间倒序列出来（同一个文件只列一次）。 */
    struct MyFileItem: Decodable, Identifiable, Hashable {
        var id: String
        var url: String?
        var name: String?
        var bytes: Int?
        var at: String?
        var chatId: String?
        var chatName: String?
        var mine: Bool?

        var fileName: String { name ?? "文件" }
        var ext: String {
            let n = fileName.lowercased()
            guard let dot = n.lastIndex(of: ".") else { return "" }
            return String(n[n.index(after: dot)...])
        }
    }
    private struct MyFilesPayload: Decodable { var files: [MyFileItem]? }

    func myFiles() async -> [MyFileItem] {
        guard let p = try? await get("/api/files/mine", as: MyFilesPayload.self) else { return [] }
        return p.files ?? []
    }

    /// 改一条收藏（编辑正文 / 改标题 / 置顶）—— 笔记的「编辑」「置顶」用它。
    /// 服务端 2026-10-12 新增 PATCH /api/favorites/<id>，改完 id 和位置都不变。
    @discardableResult
    func updateFavorite(id: String, content: String? = nil, title: String? = nil,
                        pinned: Bool? = nil) async -> Bool {
        var b: [String: Any] = [:]
        if let c = content { b["content"] = c }
        if let t = title { b["title"] = t }
        if let p = pinned { b["pinned"] = p }
        do {
            _ = try await request("PATCH", "/api/favorites/" + id, body: b)
            return true
        } catch {
            return false
        }
    }
    struct BizInvoiceResult: Decodable {
        var invoice: BizInvoiceRaw?
        var invoices: [BizInvoiceRaw]?
    }

    func biz() async throws -> BizPayload {
        try await get("/api/biz", as: BizPayload.self)
    }
    func bizSave(enabled: Bool, arrival: String, notify: Bool, autoWithdraw: Bool,
                 shopName: String, remark: String) async throws {
        let _: BizSettingsRaw = try await post("/api/biz/settings", [
            "enabled": enabled, "arrival": arrival, "notify": notify,
            "autoWithdraw": autoWithdraw, "shopName": shopName, "remark": remark
        ], as: BizSettingsRaw.self)
    }
    func bizSaveInvoice(title: String, taxNo: String, address: String, phone: String,
                        bankName: String, bankAccount: String) async throws {
        let _: BizInvoiceInfoRaw = try await post("/api/biz/invoice", [
            "title": title, "taxNo": taxNo, "address": address, "phone": phone,
            "bankName": bankName, "bankAccount": bankAccount
        ], as: BizInvoiceInfoRaw.self)
    }
    func bizApplyInvoice(amount: Double, kind: String, note: String) async throws -> [BizInvoiceRaw] {
        let r: BizInvoiceResult = try await post("/api/biz/invoice/apply",
            ["amount": amount, "kind": kind, "note": note], as: BizInvoiceResult.self)
        return r.invoices ?? []
    }
    func bizWithdraw(amount: Double, all: Bool, password: String, face: Bool) async throws -> BizWithdrawResult {
        try await post("/api/biz/withdraw",
            ["amount": amount, "all": all, "password": password, "face": face], as: BizWithdrawResult.self)
    }

    /// 常见问题（独立页面用）
    func faq() async throws -> FAQPayload {
        try await get("/api/faq", as: FAQPayload.self)
    }

    /// 我的账户等级 + 额度 + 还差哪几步
    func walletLevel() async throws -> WalletLevel {
        try await get("/api/me/wallet", as: WalletLevel.self)
    }

    /// 升级账户（服务器会检查实名 + 绑卡）
    func walletUpgrade() async throws -> WalletUpgradeResult {
        try await post("/api/me/wallet-upgrade", [:], as: WalletUpgradeResult.self)
    }

    /// 发红包：单聊只能 1 个；群聊传 count(1~100) 和 type（lucky 拼手气 / normal 普通）
    func sendRedPacket(chatId: String, amount: Double, count: Int, type: String,
                       note: String, password: String = "", face: Bool = false,
                       coverId: String = "") async throws -> RedPacketSendResult {
        try await post("/api/pay/redpacket", [
            "chatId": chatId, "amount": amount, "count": count, "type": type,
            "note": note, "password": password, "face": face, "coverId": coverId,
            /* 幂等键：超时重发 / 连点，服务端只扣一次钱 */
            "requestId": UUID().uuidString
        ], as: RedPacketSendResult.self)
    }

    /// 红包封面列表 + 我自己选的那张
    func redPacketCovers() async throws -> (covers: [RedPacketCoverRaw], defaultId: String, mine: String) {
        let r: RedPacketCoversResult = try await get("/api/redpacket/covers", as: RedPacketCoversResult.self)
        return (r.covers ?? [], r.defaultId ?? "", r.mine ?? "")
    }

    /// 选一张我自己的红包封面
    func chooseRedPacketCover(id: String) async throws {
        let _: RedPacketCoverPick = try await post("/api/redpacket/cover", ["id": id], as: RedPacketCoverPick.self)
    }

    /// 拆红包：返回这次抢到多少、余额、红包最新状态
    func claimRedPacket(id: String) async throws -> RedPacketClaimResult {
        try await post("/api/redpackets/\(id)/claim", [:], as: RedPacketClaimResult.self)
    }

    /// 红包详情：谁抢了多少、手气最佳
    func redPacketDetail(id: String) async throws -> RedPacketRaw {
        let payload: RedPacketDetailResult = try await get("/api/redpackets/\(id)", as: RedPacketDetailResult.self)
        return payload.redpacket
    }

    /// 我收到 / 我发出的红包记录
    func myRedPackets() async throws -> [RedPacketRecord] {
        let payload: RedPacketMineResult = try await get("/api/redpackets/mine", as: RedPacketMineResult.self)
        return payload.redpackets ?? []
    }

    /* ------------------------------------------------ 客服中心（腾讯/微信那套） ---------------
       常见问题（后台配）+ 在线客服（转人工 = 和「在线客服」开一个会话）+ 我的工单
       配置全在后台「客服中心」页，改完 App 里立刻生效，不用装包。 */
    struct SupportItem: Decodable, Identifiable {
        var q: String
        var a: String
        var id: String { q }
    }
    struct SupportCategory: Decodable, Identifiable {
        var id: String
        var title: String
        var icon: String?
        var items: [SupportItem]?
    }
    struct SupportAgent: Decodable {
        var id: String
        var nickname: String?
        var avatar: String?
    }
    struct SupportTicket: Decodable, Identifiable {
        var id: String
        var category: String?
        var title: String?
        var content: String?
        var status: String?
        var reply: String?
        var createdAt: String?
        var repliedAt: String?
        var doneAt: String?
    }
    struct SupportPayload: Decodable {
        var title: String?
        var searchHint: String?
        var human: Int?              // 服务器下发 1/0
        var ticketOn: Int?
        var phone: String?
        var email: String?
        var workTime: String?
        var greet: String?
        var ticketHint: String?
        var categories: [SupportCategory]?
        var agent: SupportAgent?
        var tickets: [SupportTicket]?
    }
    struct SupportHuman: Decodable {
        var chatId: String
        var agent: SupportAgent?
    }
    struct SupportTicketResult: Decodable {
        var ticket: SupportTicket?
        var tickets: [SupportTicket]?
    }

    func support() async throws -> SupportPayload {
        try await get("/api/support", as: SupportPayload.self)
    }

    /// 转人工：和「在线客服」开一个会话（已有就用原来那个），返回会话 id
    func supportHuman() async throws -> SupportHuman {
        try await post("/api/support/human", [:], as: SupportHuman.self)
    }

    /// 提交问题 → 生成一张工单（后台「客服中心 → 工单」里能看到）
    func supportTicket(category: String, content: String, contact: String = "") async throws -> [SupportTicket] {
        let payload: SupportTicketResult = try await post("/api/support/ticket",
            ["category": category, "content": content, "contact": contact],
            as: SupportTicketResult.self)
        return payload.tickets ?? []
    }

    struct LiveStart: Decodable { var sessionId: String; var joined: Bool? }
    struct LiveMember: Decodable {
        var userId: String
        var name: String?
        var avatar: String?
        var lat: Double?
        var lng: Double?
        var at: Double?
    }
    struct LiveStatePayload: Decodable {
        var sessionId: String
        var chatId: String?
        var fromId: String?
        var members: [LiveMember]
    }

    func liveStart(chatId: String, lat: Double? = nil, lng: Double? = nil) async -> (sessionId: String, joined: Bool)? {
        var body: [String: Any] = ["chatId": chatId]
        if let lat = lat, let lng = lng { body["lat"] = lat; body["lng"] = lng }
        guard let r: LiveStart = try? await post("/api/live/start", body, as: LiveStart.self) else { return nil }
        return (r.sessionId, r.joined ?? false)
    }

    func livePos(sessionId: String, lat: Double, lng: Double) async {
        _ = try? await request("POST", "/api/live/pos",
                               body: ["sessionId": sessionId, "lat": lat, "lng": lng])
    }

    func liveState(sessionId: String) async -> LiveStatePayload? {
        try? await get("/api/live/\(sessionId)/state", as: LiveStatePayload.self)
    }

    func liveStop(sessionId: String) async {
        _ = try? await request("POST", "/api/live/stop", body: ["sessionId": sessionId])
    }

    /// 修改登录密码：要验当前密码，成功后服务器把其他设备踢下线
    func changePassword(current: String, new: String) async throws {
        _ = try await request("POST", "/api/me/password",
                              body: ["currentPassword": current, "newPassword": new])
    }

    /// 退出其他设备（微信「账号与安全 → 登录设备管理 → 退出其他设备」）
    func logoutOtherDevices() async -> String? {
        do {
            _ = try await request("POST", "/api/me/logout-others", body: [:])
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? "操作失败"
        }
    }

    /* ---------------- 登录设备管理 ---------------- */

    /// 一台登录过的设备（服务端 /api/devices 下发）
    struct LoginDevice: Decodable, Identifiable, Hashable {
        var id: String
        /// 设备名（「张三的 iPhone」）——是百分号编码过的，显示前用 removingPercentEncoding 解
        var name: String?
        /// 老记录留下的那行 UA 描述（「Safari · iOS」）
        var device: String?
        /// 机型标识：iPhone17,1
        var model: String?
        /// 系统：iOS 19.1 / HarmonyOS 5.0
        var os: String?
        var ip: String?
        /// 最后登录时间（毫秒时间戳）。
        /// ⚠ 服务端老版本给的是 ISO 字符串（"2026-10-10T07:52:56.526Z"），
        /// 以前这里只有 Double，字符串解不出来 → **整个 /api/devices 响应解不出来**
        /// → 页面显示「还没有设备记录」（用户反馈「设备那三条一条都没落地」就是这个）。
        var at: Double?
        /// 是不是当前这台
        var current: Bool?

        private enum CodingKeys: String, CodingKey { case id, name, device, model, os, ip, at, current }

        /// 容错解码：数字 / ISO 字符串都收（少一条字段也不会把整页带崩）
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(String.self, forKey: .id)) ?? ""
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            device = try? c.decodeIfPresent(String.self, forKey: .device)
            model = try? c.decodeIfPresent(String.self, forKey: .model)
            os = try? c.decodeIfPresent(String.self, forKey: .os)
            ip = try? c.decodeIfPresent(String.self, forKey: .ip)
            current = try? c.decodeIfPresent(Bool.self, forKey: .current)
            if let n = try? c.decodeIfPresent(Double.self, forKey: .at) {
                at = n
            } else if let s = try? c.decodeIfPresent(String.self, forKey: .at) {
                at = LoginDevice.msOf(s)
            } else {
                at = nil
            }
        }

        /// 「2026-10-10T07:52:56.526Z」→ 毫秒时间戳；解不出来给 0
        static func msOf(_ s: String) -> Double {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 }
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 }
            return 0
        }
    }

    /// 登录设备管理：我登录过的设备（设备名 + 系统 + 最后登录时间 + 本机标记）
    func devices() async -> [LoginDevice] {
        struct Payload: Decodable { var devices: [LoginDevice]? }
        guard let p: Payload = try? await get("/api/devices", as: Payload.self) else { return [] }
        return p.devices ?? []
    }

    /// 音乐曲库（后台「音乐（听一听）」里传上去的歌；App 的「听一听」那一页 + 发音乐卡片都用它）
    func musicTracks() async -> [MusicTrack] {
        struct Payload: Decodable { var tracks: [MusicTrack]? }
        guard let p: Payload = try? await get("/api/music", as: Payload.self) else { return [] }
        return p.tracks ?? []
    }

    /// 小程序 / 小游戏（后台「小程序 / 小游戏」页里加的那些）
    /// kind 传 "game" 就只要小游戏（游戏页用）
    func miniApps(kind: String = "") async -> [MiniApp] {
        struct Payload: Decodable { var items: [MiniApp]? }
        let path = kind.isEmpty ? "/api/miniapps" : "/api/miniapps?kind=\(kind)"
        guard let p: Payload = try? await get(path, as: Payload.self) else { return [] }
        return p.items ?? []
    }

    /// 删掉某台登录设备（登录设备管理 → 编辑 → 删除；当前这台服务器不给删）
    func removeDevice(id: String) async -> String? {
        do {
            _ = try await request("POST", "/api/devices/remove", body: ["id": id])
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? "删除失败"
        }
    }

    /* ---------------------------------------------------------- 推送通知（苹果 APNs） */

    /// 把苹果给的 device token 交给服务器：手机没连实时通道时它就用这个推通知
    func registerPushToken(_ token: String, sandbox: Bool) async {
        _ = try? await request("POST", "/api/push/register", body: [
            "token": token,
            "platform": "ios",
            "env": sandbox ? "sandbox" : "prod",
            "bundleId": Bundle.main.bundleIdentifier ?? ""
        ])
    }

    /// 退出登录：这台手机别再收这个账号的推送
    func unregisterPushToken(_ token: String) async {
        guard !token.isEmpty else { return }
        _ = try? await request("POST", "/api/push/unregister", body: ["token": token])
    }

    /// 把手机上的通知设置报给服务器（允许通知没、标记有没有开）——桌面图标没数字时用来定位
    func reportPushSettings(status: String, badge: Bool, alert: Bool, sound: Bool,
                            token: String, sandbox: Bool) async {
        _ = try? await request("POST", "/api/push/settings", body: [
            "status": status, "badge": badge, "alert": alert, "sound": sound,
            "token": token, "env": sandbox ? "sandbox" : "prod"
        ])
    }

    struct PushStatus: Decodable {
        var configured: Bool?
        var enabled: Bool?
        var sandbox: Bool?
        var devices: Int?
    }

    /// 自检：服务器那边推送配好了没、这台手机登记过没（「关于」页显示用）
    func pushStatus() async -> PushStatus? {
        try? await get("/api/push/status", as: PushStatus.self)
    }

    /// 拿一对一会话（转账需要 chatId）；不是好友会报错
    func directChat(userId: String) async throws -> Chat {
        let payload: ChatPayload = try await post("/api/chats/direct", ["userId": userId], as: ChatPayload.self)
        guard let chat = payload.chat else { throw APIError.message("会话创建失败") }
        return chat
    }

    func messages(chatId: String, limit: Int = 40, before: Int? = nil) async throws -> (chat: Chat?, messages: [Message], hasMore: Bool) {
        var path = "/api/chats/\(chatId)/messages?limit=\(limit)"
        if let before = before { path += "&before=\(before)" }
        let payload: MessagesPayload = try await get(path, as: MessagesPayload.self)
        return (payload.chat, payload.messages, payload.hasMore ?? false)
    }

    func send(chatId: String, text: String) async throws -> Message? {
        let payload: MessagePayload = try await post("/api/chats/\(chatId)/messages",
                                                     ["kind": "text", "content": text],
                                                     as: MessagePayload.self)
        return payload.message
    }

    /* 群聊信息页：群成员资料（顺序和九宫格群头像一致，群主排第一） */
    func chatMembers(chatId: String) async throws -> (members: [User], ownerId: String, createdAt: String) {
        let p: ChatMembersPayload = try await get("/api/chats/\(chatId)/members", as: ChatMembersPayload.self)
        return (p.members ?? [], p.ownerId ?? "", p.createdAt ?? "")
    }

    /// 群昵称（微信「设置群昵称」/「我在本群的昵称」）。
    /// userId 传空 = 改自己的；改别人的只有群主能成。alias 传空 = 取消群昵称。
    @discardableResult
    func setGroupAlias(chatId: String, userId: String = "", alias: String) async -> Bool {
        struct P: Decodable { var alias: String? }
        var body: [String: Any] = ["alias": alias]
        if !userId.isEmpty { body["userId"] = userId }
        return (try? await post("/api/chats/\(chatId)/alias", body, as: P.self)) != nil
    }

    /* ---------------- 成长（QQ 等级那套：活跃天 / 等级） ---------------- */

    func growthMe() async throws -> GrowthMe {
        struct P: Decodable { var growth: GrowthMe }
        let p: P = try await get("/api/growth/me", as: P.self)
        return p.growth
    }

    /// 上报「这段用了我多久」（秒）——服务端按天结算活跃天
    func growthPing(seconds: Int) async throws -> GrowthMe {
        struct P: Decodable { var growth: GrowthMe }
        let p: P = try await post("/api/growth/ping", ["seconds": seconds], as: P.self)
        return p.growth
    }

    func growthRank() async throws -> (rows: [GrowthRankRow], me: GrowthRankRow?) {
        struct P: Decodable { var rank: [GrowthRankRow]?; var me: GrowthRankRow? }
        let p: P = try await get("/api/growth/rank", as: P.self)
        return (p.rank ?? [], p.me)
    }

    /* ---------------------------------------------------------- 会员（我们的） */

    /* ============================================================ 卡包（2026-10-12 照微信加）
       服务端 data/cards.json 里存的卡：优惠券 / 会员卡 / 礼品卡 / 票。
       入口在「我 → 卡包」，页面见 CardsView.swift。 */
    struct WalletCardsPayload: Decodable { var cards: [WalletCard]? }

    /// 我的卡券（按拿到的时间倒序）
    func walletCards() async -> [WalletCard] {
        guard let r: WalletCardsPayload = try? await get("/api/cards", as: WalletCardsPayload.self) else { return [] }
        return r.cards ?? []
    }

    /// 核销一张卡（用过就不能再用）
    @discardableResult
    func cardUse(id: String) async -> Bool {
        struct P: Decodable { var card: WalletCard? }
        let r: P? = try? await post("/api/cards/use", ["id": id], as: P.self)
        return (r?.card) != nil
    }

    /* 「卡包页为什么是空的」这类问题要一眼定位，所以这里把「请求成没成、拿到几条」
       原样报出来（页面第一次进来会记一条打点，见 CardsView）。 */
    func walletCardsDiag() async -> (cards: [WalletCard], note: String) {
        do {
            let any = try await request("GET", "/api/cards")
            let raw = ((any as? [String: Any])?["cards"] as? [Any])?.count ?? -1
            do {
                let data = try JSONSerialization.data(withJSONObject: any, options: [])
                let payload = try JSONDecoder().decode(WalletCardsPayload.self, from: data)
                return (payload.cards ?? [], "卡包：服务器回了 \(payload.cards?.count ?? 0) 张卡（请求成功）")
            } catch {
                return ([], "卡包：解码失败（原文 \(raw) 条）\(error)")
            }
        } catch {
            let e = error as NSError
            return ([], "卡包：请求失败 \(e.domain) #\(e.code)｜\(error.localizedDescription)")
        }
    }

    /* ============================================================ 小店（2026-10-12 照微信加）
       GET /api/shop → 商品 + 我的订单 + 零钱余额；POST /api/shop/order → 下单（走零钱扣款）。
       页面见 ShopView.swift；商品的增删改在「管理」页（/api/ops/shop）。 */

    struct ShopItem: Decodable, Identifiable, Hashable {
        var id: String
        var name: String
        var price: Double
        var img: String?
        var kind: String?
        var desc: String?
        var stock: Int?
        var on: Bool?
        var sort: Int?
        /// 实物（要收货地址）还是虚拟商品
        var isPhysical: Bool { (kind ?? "physical") != "virtual" }
        var kindName: String { isPhysical ? "实物" : "虚拟" }
    }

    struct ShopOrder: Decodable, Identifiable, Hashable {
        var id: String
        var kind: String?
        var itemId: String?
        var name: String?
        var price: Double?
        var address: String?
        var at: String?
        var status: String?
    }

    struct ShopPayload: Decodable {
        var items: [ShopItem]?
        var orders: [ShopOrder]?
        var balance: Double?
    }

    struct ShopItemsPayload: Decodable { var items: [ShopItem]? }
    struct ShopOrderPayload: Decodable { var order: ShopOrder?; var balance: Double? }

    /// 小店首页要的全部东西（商品 + 我的订单 + 零钱）
    func shopData() async throws -> ShopPayload {
        try await get("/api/shop", as: ShopPayload.self)
    }

    /// 下单：实物要收货地址；设过支付密码的用户要带上密码
    func shopOrder(itemId: String, count: Int, address: String,
                   payPassword: String) async throws -> ShopOrderPayload {
        var b: [String: Any] = ["itemId": itemId, "count": count, "address": address]
        if !payPassword.isEmpty { b["payPassword"] = payPassword }
        return try await post("/api/shop/order", b, as: ShopOrderPayload.self)
    }

    /* ============================================================ 拼多多商城（原生版，2026-10-12）
       GET  /api/mall     → { products, banners }（商城的商品和轮播图，服务器 data/mall.json 是真源）
       POST /api/ops/mall → 管理侧（上架/下架/改价/删除/新增商品 + 换轮播图），只有 ops 账号能用。
       页面见 MallNative.swift（商城）；管理侧见 MallManage.swift（管理页里的「拼多多商城」）。 */

    struct MallPayload: Decodable {
        var products: [DDProduct]?
        var banners: [String]?
        /// 商城名 / 标语（管理页里能改，用户要求「商城名」）
        var name: String?
        var slogan: String?
        /// 广告位（2026-10-15 用户：「广告要给后台插入」）——后台「商城 → 广告」里写
        var ads: [DDAd]?
        /// 配送方式 + 运费规则（2026-10-16）——后台「商城 → 配送」里写
        struct Delivery: Decodable { var modes: [DDDeliveryMode]?; var note: String? }
        var delivery: Delivery?
        /// 开屏广告（CHRIS_MALL_SPLASH_V1）：封面由管理端上传，没上传就不显示
        var splash: DDSplash?
        /// 首页宫格（CHRIS_MALL_CHANNELS_V1）：文字/图标/颜色/顺序/开关都能在管理里改
        var channels: [DDChannelItem]?
    }

    /// 商城数据：拿不到就返回空（App 会退回内置那 16 个商品，至少不是白屏）
    /// ⚠ 2026-10-17：第一个返回值改成 `ok` —— 调用方要能分清
    /// 「这次没拉回来」和「后台真的把某项清空了」。
    /// 以前分不清，结果**拉失败也当成"空配置"**：轮播图、广告位、开屏广告
    /// 全被覆盖成空（用户报的「开屏广告又没了」「商城没了」就是它）。
    func mallData() async -> (ok: Bool, products: [DDProduct], banners: [String], name: String, slogan: String,
                              ads: [DDAd], delivery: [DDDeliveryMode], splash: DDSplash?,
                              channels: [DDChannelItem]?) {
        guard let p: MallPayload = try? await get("/api/mall", as: MallPayload.self) else {
            return (false, [], [], "", "", [], [], nil, [])
        }
        /* ⚠ channels 特意**保持可选**：后台"压根没配过"是 nil（App 用内置八格兜底），
           "后台配了、但被删空了"是 []（那就该真的是空的）。
           2026-10-17 用户：「那是我删掉的」——以前两者分不清，删光了又会被内置那八格顶回来。 */
        return (true, p.products ?? [], p.banners ?? [], p.name ?? "", p.slogan ?? "",
                p.ads ?? [], p.delivery?.modes ?? [], p.splash, p.channels)
    }

    /// 管理侧改商城：action = product（新增或改一件）/ remove（删一件）/
    /// banners（整份换轮播图）/ settings（改商城名 + 标语）
    @discardableResult
    func opsMall(_ body: [String: Any]) async -> Bool {
        (try? await post("/api/ops/mall", body, as: MallPayload.self)) != nil
    }

    /// 注销账号（2026-10-17 审核合规）：confirm 必须是「注销」两个字
    func deleteAccount(confirm: String) async -> Bool {
        struct R: Decodable { var deleted: Bool? }
        let r: R? = try? await post("/api/me/delete", ["confirm": confirm], as: R.self)
        return r?.deleted == true
    }

    /* ---- 商城广告的券与分享（CHRIS_MALL_SHARE_V1 / DOT_V1）---- */
    struct MallCoupon: Decodable, Identifiable {
        var id: String
        var title: String
        var off: Double
        var min: Double
        var until: String?
        var kind: String?
        var used: Bool?
    }
    struct MallAdMine: Decodable {
        var coupons: [MallCoupon]?
        /// 上次看过之后又到账的券（商城底栏「消息」的红点）
        var newCount: Int?
        /// 还有哪些广告的券没领（「首页 / 推荐」的红点）
        var claimable: [String]?
        var claimableCount: Int?
    }
    struct MallAdClaim: Decodable {
        var already: Bool?
        var note: String?
        var coupon: MallCoupon?
    }
    struct MallAdShare: Decodable {
        var code: String?
        var text: String?
        var invited: Int?
        var need: Int?
    }

    /// 我的券 + 红点用的两个计数
    func mallAdMine() async -> MallAdMine? {
        try? await post("/api/mall/ad", ["do": "mine"], as: MallAdMine.self)
    }
    /// 打开商城「消息」时清红点
    func mallAdSeen() async {
        let _: MallAdMine? = try? await post("/api/mall/ad", ["do": "seen"], as: MallAdMine.self)
    }
    /// 点广告领券（每条广告每个账号只能领一次）
    func mallAdClaim(adId: String) async -> MallAdClaim? {
        try? await post("/api/mall/ad", ["do": "claim", "adId": adId], as: MallAdClaim.self)
    }
    /// 生成自己的邀请码（分享给好友）
    func mallAdShare(adId: String) async -> MallAdShare? {
        try? await post("/api/mall/ad", ["do": "share", "adId": adId], as: MallAdShare.self)
    }
    /// 好友点开邀请码：双方各得一张券
    struct MallInviteResult: Decodable {
        var mine: MallCoupon?
        var host: MallCoupon?
        var bonus: MallCoupon?
        var invited: Int?
        var hostName: String?
        var note: String?
    }
    func mallAdInvite(code: String, adId: String = "ad1") async -> MallInviteResult? {
        try? await post("/api/mall/ad", ["do": "invite", "code": code, "adId": adId],
                        as: MallInviteResult.self)
    }

    /* ---- 分销（CHRIS_MALL_DIST_V1）---- */
    struct DistMe: Decodable {
        var on: Bool?
        var code: String?
        var rate: Double?
        var earned: Double?
        var orders: Int?
        var pending: Int?
        var balance: Double?
        struct LogRow: Decodable, Identifiable {
            var at: String
            var text: String
            var amount: Double
            var id: String { at + text }
        }
        var log: [LogRow]?
    }
    func distMe() async -> DistMe? {
        try? await get("/api/dist/me", as: DistMe.self)
    }
    @discardableResult
    func opsDistSet(userId: String, on: Bool, rate: Double) async -> Bool {
        (try? await post("/api/ops/dist/set", ["to": userId, "on": on, "rate": rate],
                         as: SimpleOK.self)) != nil
    }
    struct DistRow: Decodable, Identifiable {
        var userId: String
        var name: String?
        var code: String?
        var rate: Double?
        var earned: Double?
        var orders: Int?
        var pending: Int?
        var id: String { userId }
    }
    func opsDistList() async -> [DistRow] {
        struct P: Decodable { var dists: [DistRow]? }
        let p: P? = try? await get("/api/ops/dist", as: P.self)
        return p?.dists ?? []
    }

    /* ---- 商城订单 / 物流 / 售后（CHRIS_MALL_ORDER_V1）---- */
    struct TrackEntry: Decodable, Identifiable, Hashable {
        var time: String
        var text: String
        /// carrier = 快递公司给的真实轨迹 · shop = 我们自己记的
        var src: String?
        var id: String { (src ?? "") + time + text }
        var isCarrier: Bool { src == "carrier" }
    }
    struct TrackPayload: Decodable {
        var id: String?
        var status: String?
        var express: Express?
        var note: String?
        var logistics: [TrackEntry]?
        struct Express: Decodable, Hashable { var company: String?; var no: String?; var code: String? }
    }
    struct OpsOrderRow: Decodable, Identifiable {
        var id: String
        var at: String?
        var total: Double?
        var status: String?
        var statusText: String?
        var address: String?
        var remark: String?
        var buyer: String?
        var items: [String]?
        var express: TrackPayload.Express?
    }

    /// 下单同步到服务器（后台才能看到并发货）
    @discardableResult
    func mallOrderSync(id: String, items: [[String: Any]], total: Double, payWay: String,
                       address: String, at: String, remark: String = "", ref: String = "",
                       paid: Bool = true) async -> Bool {
        (try? await post("/api/mall/order",
                         ["id": id, "items": items, "total": total, "payWay": payWay,
                          "address": address, "at": at, "remark": remark, "ref": ref,
                          "paid": paid],
                         as: SimpleOK.self)) != nil
    }

    /* ---------------------------------------------------------- 支付宝（官方接口，CHRIS_ALIPAY_V1）
       密钥和开关全在后台「支付配置」里，App 只拿 orderStr 去调起支付宝，
       私钥不落到客户端。 */
    /// 下单：服务端 RSA2 签名后回 orderStr（给支付宝 App 用）
    func alipayCreate(orderId: String) async throws -> (orderStr: String, sandbox: Bool) {
        struct R: Decodable { var orderStr: String?; var sandbox: Bool? }
        let p: R = try await post("/api/pay/alipay/create", ["orderId": orderId], as: R.self)
        return (p.orderStr ?? "", p.sandbox ?? false)
    }
    /// 查单：支付宝付完（异步回调也会标单）之后，App 拿这个确认
    func alipayStatus(id: String) async -> (paid: Bool, alipayNo: String) {
        struct R: Decodable { var paid: Bool?; var alipayNo: String? }
        let p: R? = try? await get("/api/pay/alipay/status?id=" + id, as: R.self)
        return (p?.paid ?? false, p?.alipayNo ?? "")
    }

    /* ---------------------------------------------------------- 真实天气（CHRIS_WEATHER_V1）
       商城二楼背景用：服务器去拉（Open-Meteo），App 不带任何密钥。
       给了定位就按定位，没给就按服务器默认点。 */
    func weather(city: String? = nil, lat: Double? = nil, lon: Double? = nil) async -> DDWeatherNow? {
        var q = ""
        if let city, !city.isEmpty {
            let c = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            q = "?city=" + c
        } else if let lat, let lon {
            q = "?lat=" + String(format: "%.3f", lat) + "&lon=" + String(format: "%.3f", lon)
        }
        return try? await get("/api/weather" + q, as: DDWeatherNow.self)
    }

    /* ---------------------------------------------------------- 城市（CHRIS_CITY_V1，美团那种顶部定位） */
    func cityHot() async -> [DDCityItem] {
        struct P: Decodable { var cities: [DDCityItem]? }
        let p: P? = try? await get("/api/city/hot", as: P.self)
        return p?.cities ?? []
    }
    func citySearch(_ q: String) async -> [DDCityItem] {
        struct P: Decodable { var cities: [DDCityItem]? }
        let s = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let p: P? = try? await get("/api/city/search?q=" + s, as: P.self)
        return p?.cities ?? []
    }
    /// 反查"我在哪个城市"（拿系统定位的经纬度去问）
    func cityHere(lat: Double, lon: Double) async -> DDCityItem? {
        struct P: Decodable { var city: String?; var lat: Double?; var lon: Double? }
        let p: P? = try? await get("/api/city/here?lat=" + String(format: "%.3f", lat)
                                   + "&lon=" + String(format: "%.3f", lon), as: P.self)
        guard let p, let n = p.city, !n.isEmpty else { return nil }
        return DDCityItem(name: n, admin: nil, country: nil, lat: p.lat ?? lat, lon: p.lon ?? lon)
    }
    /// 我的订单（服务器那份，带物流）
    func mallOrders() async -> [OpsOrderRow] {
        struct P: Decodable { var orders: [OpsOrderRow]? }
        let p: P? = try? await get("/api/mall/orders", as: P.self)
        return p?.orders ?? []
    }
    /// 物流轨迹（真实快递轨迹 + 商家记录）
    func mallTrack(orderId: String) async -> TrackPayload? {
        try? await get("/api/mall/logistics?id=" + orderId, as: TrackPayload.self)
    }
    /// 用户申请售后
    @discardableResult
    func mallAfterSale(orderId: String, kind: String, reason: String) async -> Bool {
        (try? await post("/api/mall/aftersale",
                         ["id": orderId, "kind": kind, "reason": reason],
                         as: SimpleOK.self)) != nil
    }
    /// 管理：待发货订单
    func opsMallOrders(only: String = "wait") async -> [OpsOrderRow] {
        struct P: Decodable { var orders: [OpsOrderRow]? }
        let p: P? = try? await get("/api/ops/mallorders?only=" + only, as: P.self)
        return p?.orders ?? []
    }
    /// 管理：发货（填快递公司 + 运单号）
    @discardableResult
    func opsShip(orderId: String, company: String, no: String) async -> Bool {
        (try? await post("/api/ops/ship", ["id": orderId, "company": company, "no": no],
                         as: SimpleOK.self)) != nil
    }
    /// 管理：补一条物流（派送中 / 已签收）
    @discardableResult
    func opsPushTrack(orderId: String, text: String) async -> Bool {
        (try? await post("/api/ops/logistics", ["id": orderId, "text": text],
                         as: SimpleOK.self)) != nil
    }
    /// 管理：发券（to = 用户 id 或 "all"）
    @discardableResult
    func opsSendCoupon(to: String, title: String, off: Double, min: Double, days: Int,
                       count: Int = 1, kind: String = "cash") async -> Int? {
        struct P: Decodable { var sent: Int? }
        let p: P? = try? await post("/api/ops/coupon/send",
                                    ["to": to, "title": title, "off": off, "min": min,
                                     "days": days, "count": count, "kind": kind], as: P.self)
        return p?.sent
    }
    /// 管理：售后列表
    struct AfterSaleRow: Decodable, Identifiable {
        var orderId: String
        var buyer: String?
        var total: Double?
        var item: String?
        var kind: String?
        var reason: String?
        var status: String?
        var note: String?
        var askAt: String?
        var id: String { orderId }
    }
    func opsAfterSales(only: String = "pending") async -> [AfterSaleRow] {
        struct P: Decodable { var orders: [AfterSaleRow]? }
        let p: P? = try? await get("/api/ops/aftersales?only=" + only, as: P.self)
        return p?.orders ?? []
    }
    /// 管理：售后审核（同意会退款到零钱）
    @discardableResult
    func opsAfterSaleReview(orderId: String, pass: Bool, note: String) async -> Bool {
        (try? await post("/api/ops/aftersale/review",
                         ["id": orderId, "pass": pass, "note": note], as: SimpleOK.self)) != nil
    }

    /* ============================================================ 小星（顶栏那颗眼睛）的三档
       GET/POST /api/me/eyes → { eyes: on|static|off, paid, price, balance }。
       on 是 ¥40 一次性买断（走零钱），static / off 免费。
       页面见 EyesSettingsView（我 → 设置 → 通用 → 更多 → 显示小星）。 */

    struct EyesInfo: Decodable {
        var eyes: String?
        var paid: Bool?
        var price: Double?
        var balance: Double?
        var tier: String { eyes ?? "on" }
    }

    func eyesState() async throws -> EyesInfo { try await get("/api/me/eyes", as: EyesInfo.self) }

    func eyesSet(_ tier: String) async throws -> EyesInfo {
        try await post("/api/me/eyes", ["eyes": tier], as: EyesInfo.self)
    }

    /* ============================================================ 管理侧：小店 / 卡包（ops 账号） */

    struct OpsUserRow: Decodable, Identifiable, Hashable {
        var id: String
        var username: String?
        var nickname: String?
        var avatar: String?
        var cards: Int?
    }
    struct OpsUsersPayload: Decodable { var users: [OpsUserRow]? }
    struct OpsCardsPayload: Decodable { var cards: [WalletCard]?; var userId: String? }

    /// 全部商品（含已下架的）
    func opsShopItems() async throws -> [ShopItem] {
        let r: ShopItemsPayload = try await get("/api/ops/shop", as: ShopItemsPayload.self)
        return r.items ?? []
    }

    /// 改一件商品（item 里带 id）/ 新增（newItem）/ 删除（removeId）
    func opsShopSave(item: [String: Any]?, newItem: [String: Any]?,
                     removeId: String = "") async throws -> [ShopItem] {
        var b: [String: Any] = [:]
        if !removeId.isEmpty { b["removeId"] = removeId }
        if let item = item { b["item"] = item }
        if let newItem = newItem { b["newItem"] = newItem }
        let r: ShopItemsPayload = try await post("/api/ops/shop", b, as: ShopItemsPayload.self)
        return r.items ?? []
    }

    /// 按用户名 / 昵称搜人（发卡前先找人）
    func opsCardFind(_ q: String) async throws -> [OpsUserRow] {
        let r: OpsUsersPayload = try await post("/api/ops/cards", ["action": "find", "q": q],
                                                as: OpsUsersPayload.self)
        return r.users ?? []
    }

    /// 某个人名下的卡
    func opsCardList(userId: String) async throws -> [WalletCard] {
        let r: OpsCardsPayload = try await post("/api/ops/cards",
                                                ["action": "list", "userId": userId],
                                                as: OpsCardsPayload.self)
        return r.cards ?? []
    }

    /// 发一张卡（优惠券 / 会员卡 / 礼品卡 / 票）
    func opsCardIssue(userId: String, kind: String, title: String, sub: String,
                      amount: Double, validTo: String, note: String) async throws -> [WalletCard] {
        let r: OpsCardsPayload = try await post("/api/ops/cards",
            ["action": "issue", "userId": userId, "kind": kind, "title": title,
             "sub": sub, "amount": amount, "validTo": validTo, "note": note],
            as: OpsCardsPayload.self)
        return r.cards ?? []
    }

    /// 删一张卡
    func opsCardDelete(id: String, userId: String) async throws -> [WalletCard] {
        let r: OpsCardsPayload = try await post("/api/ops/cards",
            ["action": "delete", "id": id, "userId": userId], as: OpsCardsPayload.self)
        return r.cards ?? []
    }

    /* ============================================================ App 日志 / 崩溃汇入（管理页看）
       手机上的崩溃、异常、诊断上传都走 POST /api/clientlog 落到服务器的
       data/client-errors.jsonl；这里给 ops 账号一个「汇入之后能看」的入口。 */

    struct AppLogRow: Decodable, Identifiable, Hashable {
        var id: String
        var kind: String?
        var text: String?
        var stack: String?
        var app: String?
        var user: String?
        var ip: String?
        var at: String?
    }
    struct AppLogKind: Decodable, Hashable {
        var kind: String
        var n: Int
    }
    struct AppLogsPayload: Decodable {
        var total: Int?
        var kinds: [AppLogKind]?
        var rows: [AppLogRow]?
    }

    /// 汇入的 App 日志 / 崩溃（只有 ops 账号拿得到）
    func opsLogs(kind: String = "", limit: Int = 50) async throws -> AppLogsPayload {
        var path = "/api/ops/logs?limit=" + String(limit)
        if !kind.isEmpty {
            path += "&kind=" + (kind.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        }
        return try await get(path, as: AppLogsPayload.self)
    }

    /// 「体检」用：带令牌打一个接口，回「状态码 + 耗时 + 一句话」
    /// （404 说明这条线路的服务器太旧、没有这条路由 —— 卡包为空那种问题一眼看出来）
    func healthProbe(_ path: String) async -> (code: Int, ms: Int, note: String) {
        guard let url = URL(string: base + path) else { return (-1, 0, "地址拼不出来") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(AppInfo.build, forHTTPHeaderField: "X-App-Build")
        req.setValue(AppInfo.deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue(AppInfo.deviceKind, forHTTPHeaderField: "X-Device-Kind")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let t0 = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            var note = "HTTP " + String(code) + " · " + String(ms) + "ms · " + String(data.count) + " 字节"
            if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (o["ok"] as? Bool) == true, let d = o["data"] as? [String: Any] {
                if let n = countOf(d, "items") { note += " · " + String(n) + " 项" }
                else if let n = countOf(d, "chats") { note += " · " + String(n) + " 个会话" }
                else if let n = countOf(d, "cards") { note += " · " + String(n) + " 张卡" }
                else if let n = countOf(d, "friends") { note += " · " + String(n) + " 位好友" }
                else if let n = countOf(d, "orders") { note += " · " + String(n) + " 个订单" }
                else if let n = countOf(d, "tracks") { note += " · " + String(n) + " 首歌" }
                else if let eyes = d["eyes"] as? String { note += " · 小星 " + eyes }
            } else if code == 404 {
                note += " · 这条线路的服务器没有这个接口（服务器太旧）"
            } else if code == 401 {
                note += " · 登录态失效（要重新登录）"
            }
            return (code, ms, note)
        } catch {
            return (-1, 0, "连不上：" + error.localizedDescription)
        }
    }

    private func countOf(_ d: [String: Any], _ key: String) -> Int? {
        (d[key] as? [Any])?.count
    }

    /* ============================================================ 红包封面（管理页可换）
       和后台 manage.html 的「红包封面」是同一份数据（data/redpacket-covers.json）：
         GET  /api/ops/rpcovers → { covers: { defaultId, covers: [...] } }（含停用的）
         POST /api/ops/rpcovers ← { covers: [...], defaultId }（整份覆盖，跟后台同一套校验） */

    struct RPCover: Decodable, Identifiable, Hashable {
        var id: String
        var name: String?
        var image: String?
        var thumb: String?
        var color: String?
        var enabled: Bool?
    }
    struct RPCoversFile: Decodable {
        var defaultId: String?
        var covers: [RPCover]?
    }
    private struct RPCoversPayload: Decodable { var covers: RPCoversFile? }
    private struct RPSavedPayload: Decodable { var covers: RPCoversFile? }

    func opsRPCovers() async throws -> (covers: [RPCover], defaultId: String) {
        let r: RPCoversPayload = try await get("/api/ops/rpcovers", as: RPCoversPayload.self)
        return (r.covers?.covers ?? [], r.covers?.defaultId ?? "")
    }

    @discardableResult
    func opsRPSave(covers: [[String: Any]], defaultId: String) async throws -> [RPCover] {
        var b: [String: Any] = ["covers": covers]
        if !defaultId.isEmpty { b["defaultId"] = defaultId }
        let r: RPSavedPayload = try await post("/api/ops/rpcovers", b, as: RPSavedPayload.self)
        return r.covers?.covers ?? []
    }

    /* ============================================================ 管理：改一个开关（ops）
       写的是 data/ui.json 里的一个键（比如「实名前先刷脸」realnameFace）。
       /api/ui 每次现读文件，所以改完把 UI 配置重拉一次就生效。 */
    @discardableResult
    func opsSetUIKey(_ key: String, _ value: Any) async -> Bool {
        do {
            _ = try await request("POST", "/api/ops/ui", body: ["key": key, "value": value])
            return true
        } catch {
            return false
        }
    }

    /// 会员中心要的全部东西：档位 + 价格 + 权益文案 + 我的状态 + 开通记录
    func memberInfo() async throws -> MemberInfo {
        struct P: Decodable { var membership: MemberInfo? }
        let p: P = try await get("/api/membership", as: P.self)
        return p.membership ?? MemberInfo()
    }

    /// 开通 / 续费：走零钱扣款，要支付密码（没设密码就传空）
    func memberOpen(tierId: String, months: Int, payPassword: String) async -> (MemberMe?, Double?, String?) {
        struct P: Decodable { var membership: MemberMe?; var balance: Double?; var paid: Double? }
        do {
            let p: P = try await post("/api/membership/open",
                                      ["tierId": tierId, "months": months, "payPassword": payPassword],
                                      as: P.self)
            return (p.membership, p.balance, nil)
        } catch {
            return (nil, nil, (error as? APIError)?.errorDescription ?? "开通失败，再试一次")
        }
    }

    /// 自动续费开关
    func memberAuto(_ on: Bool) async {
        struct P: Decodable { var membership: MemberMe? }
        _ = try? await post("/api/membership/auto", ["on": on], as: P.self)
    }

    /// 兑换码
    func memberRedeem(_ code: String) async -> (String?, String) {
        struct P: Decodable { var membership: MemberMe?; var tier: String?; var days: Int? }
        do {
            let p: P = try await post("/api/membership/redeem", ["code": code], as: P.self)
            return (p.tier, "兑换成功：" + (p.tier ?? "会员") + " " + String(p.days ?? 0) + " 天")
        } catch {
            return (nil, (error as? APIError)?.errorDescription ?? "兑换失败")
        }
    }

    /// 扫一扫 → 翻译：把识别到的文字发给服务器，用后台配的大模型翻
    func scanTranslate(_ text: String, to: String = "中文") async -> String? {
        struct P: Decodable { var text: String? }
        guard let p: P = try? await post("/api/scan/translate", ["text": text, "to": to], as: P.self) else {
            return nil
        }
        return p.text
    }

    /* 置顶聊天 / 取消置顶（群聊信息页那一行） */
    @discardableResult
    func setPinned(chatId: String, pinned: Bool) async -> Bool {
        let p: PinPayload? = try? await post("/api/chats/\(chatId)/pin",
                                             ["pinned": pinned], as: PinPayload.self)
        return p?.pinned ?? pinned
    }

    /* ---------------- 群管理（对应功能清单里的群名称/群公告/群屏蔽/踢人/解散）---------------- */

    /// 改群名称 / 群公告（只有群主）。返回错误文案，nil = 成功
    @discardableResult
    func updateChatInfo(chatId: String, name: String, announce: String) async -> String? {
        do {
            let _: ChatInfoPayload = try await patch("/api/chats/\(chatId)/info",
                                                     ["name": name, "announce": announce], as: ChatInfoPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "保存失败" }
    }

    /// 消息免打扰（群屏蔽）：每个人自己设
    @discardableResult
    func setMuted(chatId: String, muted: Bool) async -> Bool {
        let p: MutePayload? = try? await post("/api/chats/\(chatId)/mute", ["muted": muted], as: MutePayload.self)
        return p?.muted ?? muted
    }

    /// 群主把某个成员移出群聊
    @discardableResult
    func kickMember(chatId: String, userId: String) async -> String? {
        do {
            let _: GroupActionPayload = try await post("/api/chats/\(chatId)/kick",
                                                       ["userId": userId], as: GroupActionPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "移出失败" }
    }

    /// 群二维码：拿到邀请码和二维码 SVG
    /// 群加人：把选中的好友拉进群（群里任何成员都能拉，群上限 500）
    func addGroupMembers(chatId: String, userIds: [String]) async -> (added: [String], memberCount: Int, error: String?) {
        struct Payload: Decodable {
            var memberCount: Int?
            var added: [Row]?
            struct Row: Decodable { var id: String?; var name: String? }
        }
        do {
            let p: Payload = try await post("/api/chats/\(chatId)/add-members",
                                            ["userIds": userIds], as: Payload.self)
            let names = (p.added ?? []).compactMap { $0.name }
            return (names, p.memberCount ?? 0, nil)
        } catch {
            return ([], 0, (error as? APIError)?.errorDescription ?? "加人失败")
        }
    }

    /// 我的二维码（每个人一张，扫了能加好友）
    /* ---------------- 隐私 / 消息通知 ---------------- */
    func privacy() async -> PrivacySettings {
        struct Payload: Decodable {
            var privacy: Raw?; var notify: Raw?
            struct Raw: Decodable {
                var needVerify: Bool?; var strangerMoments: Bool?
                var addByWx: Bool?; var addByPhone: Bool?; var addByGroup: Bool?; var addByQR: Bool?
                /// 朋友圈可见范围：3d / 6m / all
                var momentsRange: String?
            }
        }
        guard let p: Payload = try? await get("/api/me/privacy", as: Payload.self), let r = p.privacy
        else { return PrivacySettings() }
        var s = PrivacySettings()
        s.needVerify = r.needVerify ?? true
        s.strangerMoments = r.strangerMoments ?? false
        s.addByWx = r.addByWx ?? true
        s.addByPhone = r.addByPhone ?? true
        s.addByGroup = r.addByGroup ?? true
        s.addByQR = r.addByQR ?? true
        s.momentsRange = (r.momentsRange == "3d" || r.momentsRange == "6m") ? r.momentsRange! : "all"
        return s
    }

    func setPrivacy(_ key: String, _ value: Bool) async {
        _ = try? await request("PATCH", "/api/me/privacy", body: [key: value])
    }

    /// 隐私设置里那种**不是开关**的项（比如朋友圈可见范围 3d / 6m / all）
    func setPrivacyText(_ key: String, _ value: String) async {
        _ = try? await request("PATCH", "/api/me/privacy", body: [key: value])
    }

    func notifySettings() async -> NotifySettings {
        struct Payload: Decodable {
            var notify: Raw?
            struct Raw: Decodable {
                var on: Bool?; var sound: Bool?; var vibrate: Bool?; var showDetail: Bool?
                var muteStart: String?; var muteEnd: String?
            }
        }
        guard let p: Payload = try? await get("/api/me/privacy", as: Payload.self), let r = p.notify
        else { return NotifySettings() }
        var s = NotifySettings()
        s.on = r.on ?? true
        s.sound = r.sound ?? true
        s.vibrate = r.vibrate ?? true
        s.showDetail = r.showDetail ?? true
        s.muteStart = r.muteStart ?? ""
        s.muteEnd = r.muteEnd ?? ""
        return s
    }

    func setNotify(_ fields: [String: Any]) async {
        _ = try? await request("PATCH", "/api/me/notify", body: fields)
    }

    func myQRCode() async -> (code: String, url: String, rows: [String], user: User?) {
        struct MyQRPayload: Decodable {
            var code: String?; var url: String?; var rows: [String]?; var user: User?
        }
        guard let p: MyQRPayload = try? await get("/api/me/qrcode", as: MyQRPayload.self)
        else { return ("", "", [], nil) }
        return (p.code ?? "", p.url ?? "", p.rows ?? [], p.user)
    }

    /// 扫到别人的个人二维码：**只解析出这是谁**（不直接加好友）——微信是跳资料页再点「添加到通讯录」
    func userByCode(_ code: String) async -> (user: User?, relation: String, message: String) {
        struct ByCodePayload: Decodable { var user: User?; var relation: String? }
        do {
            let p: ByCodePayload = try await post("/api/user-by-code", ["code": code], as: ByCodePayload.self)
            return (p.user, p.relation ?? "none", "")
        } catch {
            return (nil, "", (error as? APIError)?.errorDescription ?? "这个二维码无效或者过期了")
        }
    }

    /// 扫到别人的个人二维码：加好友。返回 (提示文案, 对方)
    func addByCode(_ code: String) async -> (message: String, user: User?) {
        struct AddPayload: Decodable {
            var sent: Bool?; var already: Bool?; var pending: Bool?; var accepted: Bool?; var user: User?
        }
        do {
            let p: AddPayload = try await post("/api/add-by-code", ["code": code], as: AddPayload.self)
            let msg = p.already == true ? "你们已经是好友了"
                : (p.pending == true ? "已经发过申请了，等对方通过"
                   : (p.accepted == true ? "对方之前加过你，现在已经是好友" : "好友申请已发出"))
            return (msg, p.user)
        } catch {
            return ((error as? APIError)?.errorDescription ?? "加好友失败", nil)
        }
    }

    func groupInvite(chatId: String) async -> (code: String, url: String, rows: [String]) {
        struct InvitePayload: Decodable { var code: String?; var url: String?; var svg: String?; var rows: [String]? }
        guard let p: InvitePayload = try? await post("/api/chats/\(chatId)/invite", [:], as: InvitePayload.self)
        else { return ("", "", []) }
        return (p.code ?? "", p.url ?? "", p.rows ?? [])
    }

    /// 扫码进群：成功返回这个会话（调用方拿到就能直接跳进群聊），失败返回错误文案
    func joinByInvite(code: String) async -> (chat: Chat?, error: String?) {
        struct JoinPayload: Decodable {
            var joined: Bool?
            var already: Bool?
            var chat: Chat?
        }
        do {
            let p: JoinPayload = try await post("/api/join", ["code": code], as: JoinPayload.self)
            return (p.chat, nil)
        } catch {
            return (nil, (error as? APIError)?.errorDescription ?? "进群失败")
        }
    }

    /// 全员禁言（群主）
    @discardableResult
    func setMuteAll(chatId: String, on: Bool) async -> String? {
        do {
            struct MuteAllPayload: Decodable { var muteAll: Bool? }
            let _: MuteAllPayload = try await post("/api/chats/\(chatId)/muteall", ["on": on], as: MuteAllPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "设置失败" }
    }

    /// 禁言 / 取消禁言某个群成员（群主）
    @discardableResult
    func setMemberMuted(chatId: String, userId: String, muted: Bool) async -> String? {
        do {
            _ = try await post("/api/chats/\(chatId)/mutemember",
                               ["userId": userId, "muted": muted], as: SendPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "设置失败" }
    }

    /// 退出群聊（群主退群会自动把群主交给下一个人）
    @discardableResult
    func leaveGroup(chatId: String) async -> String? {
        do {
            let _: GroupActionPayload = try await post("/api/chats/\(chatId)/leave", [:], as: GroupActionPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "退群失败" }
    }

    /// 解散群聊（只有群主）
    @discardableResult
    func dismissGroup(chatId: String) async -> String? {
        do {
            let _: GroupActionPayload = try await post("/api/chats/\(chatId)/dismiss", [:], as: GroupActionPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "解散失败" }
    }

    /// 清空聊天记录（只清自己这边）
    @discardableResult
    func clearChat(chatId: String) async -> String? {
        do {
            let _: GroupActionPayload = try await post("/api/chats/\(chatId)/clear", [:], as: GroupActionPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "清空失败" }
    }

    /// 查找聊天记录：在服务器上翻整个会话的历史
    func searchMessages(chatId: String, query: String) async -> [FoundMessage] {
        guard let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let p: SearchPayload = try? await get("/api/chats/\(chatId)/search?q=\(q)", as: SearchPayload.self)
        else { return [] }
        return p.messages
    }

    /* ---------------- 银行卡 ---------------- */

    func bankCards() async -> [BankCard] {
        let p: BankCardsPayload? = try? await get("/api/me/bankcards", as: BankCardsPayload.self)
        return p?.cards ?? []
    }

    struct BankInfo: Decodable, Identifiable, Hashable {
        var name: String
        var color: String?
        var short: String?
        var id: String { name }
    }
    private struct BankListPayload: Decodable { var banks: [BankInfo]? }

    /// 绑卡时能选的银行（名字 + 品牌色）
    func banks() async -> [BankInfo] {
        let p: BankListPayload? = try? await get("/api/banks", as: BankListPayload.self)
        return p?.banks ?? []
    }

    /// 改一张卡的「免密支付」开关
    func setBankCardNoPin(id: String, noPin: Bool) async {
        _ = try? await patch("/api/me/bankcards/" + id, ["noPin": noPin], as: [String: String].self)
    }

    @discardableResult
    func addBankCard(bank: String, number: String, holder: String,
                     idCard: String = "", phone: String = "", type: String = "") async -> String? {
        do {
            let _: BankCardsPayload = try await post("/api/me/bankcards",
                                                     ["bank": bank, "number": number, "holder": holder,
                                                      "idCard": idCard, "phone": phone, "type": type],
                                                     as: BankCardsPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "绑定失败" }
    }

    @discardableResult
    func deleteBankCard(id: String) async -> String? {
        do {
            _ = try await request("DELETE", "/api/me/bankcards/\(id)")
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "解绑失败" }
    }

    /* ---------------- 意见反馈 / 密码找回 ---------------- */

    @discardableResult
    func sendFeedback(content: String, contact: String,
                      category: String = "功能异常", images: [String] = []) async -> String? {
        do {
            let _: SendPayload = try await post("/api/feedback",
                                                ["content": content, "contact": contact,
                                                 "category": category, "images": images,
                                                 "platform": "iOS"],
                                                as: SendPayload.self)
            return nil
        } catch { return (error as? APIError)?.errorDescription ?? "提交失败" }
    }

    /// 我的反馈（微信「意见反馈」下面能看到自己提过的 + 官方回复）
    struct MyFeedback: Decodable, Identifiable, Hashable {
        var id: String
        var category: String?
        var content: String?
        var images: [String]?
        var createdAt: String?
        var status: String?
        var reply: String?
        var repliedAt: String?
    }
    private struct MyFeedbackPayload: Decodable { var rows: [MyFeedback]? }
    func myFeedback() async -> [MyFeedback] {
        guard let p: MyFeedbackPayload = try? await get("/api/feedback/mine", as: MyFeedbackPayload.self) else { return [] }
        return p.rows ?? []
    }

    /// 密码找回：手机号 + 验证码 + 新密码。
    /// 成功后返回这个账号的用户名（App 用用户名+新密码再登一次，就进 App 了）
    func resetPassword(phone: String, code: String, newPassword: String) async -> (username: String, error: String?) {
        do {
            let p: LoginPayload = try await post("/api/login/reset",
                                                 ["phone": phone, "code": code, "newPassword": newPassword],
                                                 as: LoginPayload.self)
            return (p.user?.username ?? "", nil)
        } catch { return ("", (error as? APIError)?.errorDescription ?? "重置失败") }
    }

    func markRead(chatId: String) async {
        _ = try? await request("POST", "/api/chats/\(chatId)/read", body: [:])
    }

    /* ---------------- 聊天记录导出 / 导入 ---------------- */

    /// 导出结果：文件名 + 格式 + 内容。
    /// json 是「可以再导入」的备份（payload），txt 是给人看的（text）。
    struct ChatDump {
        var fileName = "luchat-chat.json"
        var format = "json"
        var total = 0
        var chats = 0
        var text = ""
        /// json 格式时的原始对象，直接拿去导入
        var payload: Any? = nil
    }

    /// 导出聊天记录：chatId 传空就是全部
    func exportChats(chatId: String = "", format: String = "json") async throws -> ChatDump {
        var path = "/api/chats/export?format=" + format
        if !chatId.isEmpty { path += "&chatId=" + chatId }
        let any = try await request("GET", path)
        guard let dict = any as? [String: Any] else { throw APIError.message("导出失败") }
        var out = ChatDump()
        out.fileName = (dict["fileName"] as? String) ?? out.fileName
        out.format = (dict["format"] as? String) ?? format
        out.total = (dict["total"] as? Int) ?? 0
        out.chats = (dict["chats"] as? Int) ?? 0
        if out.format == "txt" {
            out.text = (dict["data"] as? String) ?? ""
        } else {
            out.payload = dict["data"]
        }
        return out
    }

    /// 把导出的 JSON 合回来（按消息 id 去重）
    func importChats(payload: Any) async throws -> (imported: Int, skipped: Int, chats: Int) {
        struct Out: Decodable { var imported: Int?; var skipped: Int?; var chats: Int? }
        let out: Out = try await post("/api/chats/import", ["payload": payload], as: Out.self)
        return (out.imported ?? 0, out.skipped ?? 0, out.chats ?? 0)
    }

    func markUnread(chatId: String) async {
        _ = try? await request("POST", "/api/chats/\(chatId)/unread", body: [:])
    }

    /// 清空聊天记录 + 从列表里移除（微信的「删除」）。返回错误文案，nil = 成功
    @discardableResult
    func deleteChat(chatId: String) async -> String? {
        await deleteChat(path: "/api/chats/\(chatId)?clear=1")
    }

    /// 不显示该聊天：只从自己的列表里移除，对方不受影响。返回错误文案，nil = 成功
    @discardableResult
    func hideChat(chatId: String) async -> String? {
        await deleteChat(path: "/api/chats/\(chatId)")
    }

    private func deleteChat(path: String) async -> String? {
        do {
            _ = try await request("DELETE", path)
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? "操作失败"
        }
    }

    func openDirect(userId: String) async throws -> Chat? {
        let payload: ChatPayload = try await post("/api/chats/direct", ["userId": userId], as: ChatPayload.self)
        return payload.chat
    }

    func contacts() async throws -> [User] {
        let payload: ContactsPayload = try await get("/api/contacts", as: ContactsPayload.self)
        return payload.friends
    }

    func contactsFull() async throws -> (friends: [User], incoming: [User]) {
        let payload: ContactsPayload = try await get("/api/contacts", as: ContactsPayload.self)
        return (payload.friends, payload.incoming ?? [])
    }

    /// 「新的朋友」页要的全部东西：好友 / 别人加我的 / 我加别人的 / 刚通过的（显示「已添加」）
    func friendRequests() async throws -> (friends: [User], incoming: [User], outgoing: [User], added: [User]) {
        let p: ContactsPayload = try await get("/api/contacts", as: ContactsPayload.self)
        return (p.friends, p.incoming ?? [], p.outgoing ?? [], p.added ?? [])
    }

    private struct BadgeCountsPayload: Decodable { var friendRequests: Int?; var momentUnread: Int? }
    /// 红点数字（很轻的接口）：回到前台 / 定时兜底查一下，防止漏推送
    func badgeCounts() async -> (friendRequests: Int, momentUnread: Int)? {
        guard let p = try? await get("/api/badge-counts", as: BadgeCountsPayload.self) else { return nil }
        return (p.friendRequests ?? 0, p.momentUnread ?? 0)
    }

    /// 同意 / 拒绝好友申请。
    /// 传 requestId（「新的朋友」列表里本来就带着），或者 userId（对方名片上直接点同意 ——
    /// 以前得先拉一遍整份通讯录去找 requestId，点一下要等两次网络来回，所以才显得慢）。
    /// 返回 ok = 服务端认了；pending = 还剩几个待处理（老服务端不给这个字段，就保持客户端自己算的）。
    @discardableResult
    func respondFriend(requestId: String = "", userId: String = "",
                       accept: Bool) async -> (ok: Bool, pending: Int?) {
        struct RespondPayload: Decodable { var pending: Int? }
        var body: [String: Any] = ["accept": accept]
        if !requestId.isEmpty { body["requestId"] = requestId }
        if !userId.isEmpty { body["userId"] = userId }
        guard let p = try? await post("/api/friends/respond", body, as: RespondPayload.self) else {
            return (false, nil)
        }
        return (true, p.pending)
    }

    func createGroup(name: String, memberIds: [String]) async throws -> Chat? {
        let payload: ChatPayload = try await post("/api/chats/group",
                                                  ["name": name, "memberIds": memberIds],
                                                  as: ChatPayload.self)
        return payload.chat
    }

    /// 面对面建群（微信那套）：大家输入**同一个 4 位数字**就进同一个群，
    /// 数字 3 分钟内有效，每次有人进来重新计时。返回进/建好的那个群。
    func faceGroup(code: String) async throws -> Chat? {
        struct FacePayload: Decodable {
            var chat: Chat?
            var created: Bool?
            var joined: Bool?
            var memberCount: Int?
            var expiresIn: Int?
        }
        let payload: FacePayload = try await post("/api/chats/face", ["code": code], as: FacePayload.self)
        return payload.chat
    }

    func recharge(_ amount: Double) async throws -> Double {
        struct RechargePayload: Decodable { var balance: Double? }
        let payload: RechargePayload = try await post("/api/me/recharge",
                                                      ["amount": amount,
                                                       "requestId": UUID().uuidString],
                                                      as: RechargePayload.self)
        return payload.balance ?? 0
    }

    /// 收款：成功返回 nil，失败**返回原因**。
    /// ⚠ 以前这里是静默 `try?` —— 服务端说「已过期 / 不是给你的 / 已经收过了」时
    /// 客户端一个字都不提示，用户看到的就是「点了没反应」。现在把原因带回去。
    @discardableResult
    func claimTransfer(_ id: String) async -> String? {
        do {
            _ = try await request("POST", "/api/transfers/\(id)/claim", body: [:])
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? "收款失败，稍后再试"
        }
    }

    /// 付款方提醒对方收款（服务端真的会把提醒推给对方，1 分钟只能提醒一次）
    @discardableResult
    func remindTransfer(_ id: String) async -> String? {
        do {
            _ = try await request("POST", "/api/transfers/\(id)/remind", body: [:])
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? "提醒失败"
        }
    }

    /// 收款方「退还」：把钱原路退给付款方（微信转账详情里收款方那颗按钮）
    @discardableResult
    func refundTransfer(_ id: String) async -> String? {
        do {
            _ = try await request("POST", "/api/transfers/\(id)/refund", body: [:])
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? "退还失败"
        }
    }

    func favorites() async -> [[String: Any]] {
        guard let any = try? await request("GET", "/api/favorites"),
              let dict = any as? [String: Any],
              let list = dict["favorites"] as? [[String: Any]] else { return [] }
        return list
    }

    /// 收藏一条聊天内容（长按消息 → 收藏）
    @discardableResult
    func addFavorite(kind: String, content: String, title: String = "", from: String = "") async -> Bool {
        let ok = try? await request("POST", "/api/favorites", body: [
            "kind": kind, "content": content, "title": title, "from": from
        ])
        return ok != nil
    }

    /* ---------------- 实名认证 ---------------- */

    struct RealNameInfo: Hashable {
        var verified: Bool
        var realName: String
        var idMask: String
        var at: String
    }

    func realNameStatus() async -> RealNameInfo {
        guard let any = try? await request("GET", "/api/me/realname"),
              let d = any as? [String: Any] else {
            return RealNameInfo(verified: false, realName: "", idMask: "", at: "")
        }
        return RealNameInfo(verified: (d["verified"] as? Bool) ?? false,
                            realName: (d["realName"] as? String) ?? "",
                            idMask: (d["idMask"] as? String) ?? "",
                            at: (d["at"] as? String) ?? "")
    }

    /// 提交实名认证（服务端校验身份证号 + 一人一证）
    func submitRealName(name: String, idCard: String) async throws -> RealNameInfo {
        let any = try await request("POST", "/api/me/realname", body: ["realName": name, "idCard": idCard])
        let d = (any as? [String: Any]) ?? [:]
        return RealNameInfo(verified: (d["verified"] as? Bool) ?? true,
                            realName: (d["realName"] as? String) ?? name,
                            idMask: (d["idMask"] as? String) ?? "",
                            at: (d["at"] as? String) ?? "")
    }

    /* ---------------- 地区（省 / 市）· 换手机号 ---------------- */

    struct RegionRow: Decodable, Hashable {
        var p: String            // 省 / 直辖市
        var c: [String]          // 市
    }

    /// 省 / 市列表（地区选择用：和微信一样两个滚轮）。服务端内置，一次拉回。
    func regions() async -> [RegionRow] {
        guard let any = try? await request("GET", "/api/regions") else { return [] }
        let d = (any as? [String: Any]) ?? [:]
        return (try? decode(d["regions"] ?? [], as: [RegionRow].self)) ?? []
    }

    /// 换手机号第一步：给新号发验证码。没配短信通道时服务端回 devCode（本机/局域网直接显示）
    func phoneChangeCode(phone: String) async throws -> String? {
        let any = try await request("POST", "/api/me/phone/code", body: ["phone": phone])
        return (any as? [String: Any])?["devCode"] as? String
    }

    /// 换手机号第二步：提交新号 + 验证码（没配短信通道时改用登录密码验证）
    @discardableResult
    func changePhone(phone: String, code: String, password: String) async throws -> String {
        var body: [String: Any] = ["phone": phone, "code": code]
        if !password.isEmpty { body["password"] = password }
        let any = try await request("POST", "/api/me/phone", body: body)
        return ((any as? [String: Any])?["phone"] as? String) ?? ""
    }

    func changeBackground(_ path: String) async {
        await updateMe(["chatBackground": path])
    }

    /// 「聊天背景」页要的壁纸清单（后台「聊天壁纸」页配的：默认壁纸 + 基础壁纸）。
    /// 拉不到就返回 nil —— 那一页会退回它自己内置的 6 张，老服务器/断网都不会白屏。
    func chatBackgrounds() async -> ChatBgPayload? {
        try? await get("/api/chat-bg", as: ChatBgPayload.self)
    }

    func moments(limit: Int = 20, userId: String? = nil) async throws -> [Moment] {
        var path = "/api/moments?limit=\(limit)"
        if let userId = userId, !userId.isEmpty { path += "&userId=\(userId)" }
        let payload: MomentsPayload = try await get(path, as: MomentsPayload.self)
        return payload.moments
    }

    /// 朋友圈首页要的完整信息：列表 + 有没有新的（「发现」上的小红点）+ 还有没有更多
    ///（before = 上一页最后一条的时间，用来往下翻页）
    func momentsFeed(limit: Int = 20, before: String? = nil, beforeId: String? = nil, userId: String? = nil)
        async throws -> (moments: [Moment], unread: Int, total: Int, hasMore: Bool, range: String,
                         noticeUnread: Int) {
        var path = "/api/moments?limit=\(limit)"
        if let before = before, !before.isEmpty { path += "&before=\(before)" }
        if let beforeId = beforeId, !beforeId.isEmpty { path += "&beforeId=\(beforeId)" }
        if let userId = userId, !userId.isEmpty { path += "&userId=\(userId)" }
        let payload: MomentsPayload = try await get(path, as: MomentsPayload.self)
        return (payload.moments, payload.unread ?? 0, payload.total ?? payload.moments.count,
                payload.hasMore ?? false, payload.range ?? "all", payload.noticeUnread ?? 0)
    }

    /* ---------------------------------------------------------- 更多接口 */

    func plusPanel() async throws -> [PlusItem] {
        let payload: PlusPayload = try await get("/api/plus-panel", as: PlusPayload.self)
        return (payload.items ?? []).filter { $0.enabled != false }
    }

    /// 聊天输入栏那一整份配置：＋面板 + 快捷按钮 + 「＋」按钮外观（一次拉全，别再发两次请求）
    func plusConfig() async throws -> (items: [PlusItem], quick: [QuickChip], plus: PlusButtonCfg) {
        let payload: PlusConfigPayload = try await get("/api/plus-panel", as: PlusConfigPayload.self)
        return ((payload.items ?? []).filter { $0.enabled != false },
                payload.quick ?? [],
                payload.plus ?? PlusButtonCfg())
    }

    /// 管理里改完「聊天快捷」保存（只传要改的那几项，服务端按字段合并）
    func saveChatQuick(quick: [QuickChip], plus: PlusButtonCfg) async throws {
        let body: [String: Any] = [
            "quick": quick.map { ["id": $0.id, "label": $0.label, "action": $0.action, "enabled": $0.enabled] },
            "plus": ["color": plus.color, "size": plus.size, "image": plus.image]
        ]
        _ = try await request("PUT", "/api/ops/plus-panel", body: body)
    }

    /// 管理页用：拉不到就返回空的（页面照样能打开，用本机那套默认值兜底）
    func plusConfigSafe() async -> (quick: [QuickChip], plus: PlusButtonCfg) {
        guard let c = try? await plusConfig() else { return ([], PlusButtonCfg()) }
        return (c.quick, c.plus)
    }

    func gifts() async throws -> [Gift] {
        let payload: GiftsPayload = try await get("/api/gifts", as: GiftsPayload.self)
        return payload.gifts ?? []
    }

    func stickerPacks() async throws -> [StickerPack] {
        let payload: StickersPayload = try await get("/api/stickers", as: StickersPayload.self)
        return payload.packs ?? []
    }

    /* ---------------------------------------------------------- 表情（微信「我 → 表情」） */

    /// 表情商店 + 我的表情一次拿全
    func stickerShop() async throws -> (shop: [StickerPack], mine: StickerMine) {
        let p: StickerShopPayload = try await get("/api/stickers", as: StickerShopPayload.self)
        return (p.packs ?? [], p.mine ?? StickerMine())
    }

    /// 添加表情包（商店里点「添加」）
    func addStickerPack(_ packId: String) async {
        _ = try? await request("POST", "/api/stickers/add", body: ["packId": packId])
    }

    /// 移除表情包（我的表情里点「移除」）
    func removeStickerPack(_ packId: String) async {
        _ = try? await request("POST", "/api/stickers/remove", body: ["packId": packId])
    }

    /// 添加单个表情（从相册选一张图上传后加进「我添加的表情」）
    func addSingleSticker(_ sticker: String) async {
        _ = try? await request("POST", "/api/stickers/add", body: ["sticker": sticker])
    }

    func removeSingleSticker(_ sticker: String) async {
        _ = try? await request("POST", "/api/stickers/remove", body: ["sticker": sticker])
    }

    /// 用过的表情记一笔（表情面板第一格「最近使用」）
    func markStickerUsed(_ sticker: String) async {
        _ = try? await request("POST", "/api/stickers/recent", body: ["sticker": sticker])
    }

    func statusCategories() async throws -> [StatusCategory] {
        let payload: StatusesPayload = try await get("/api/statuses", as: StatusesPayload.self)
        return payload.categories ?? []
    }

    /// 发现页那几行（后台配的，网页版和 App 共用一份）
    func discover() async throws -> [DiscoverItem] {
        let payload: DiscoverPayload = try await get("/api/discover", as: DiscoverPayload.self)
        return payload.items.filter { $0.enabled != false }
    }

    /// 新闻（发现 → 星联世界）：source = qq / toutiao / sina / weibo / baidu
    /// 服务端多源聚合 + 5 分钟缓存；返回里还带一份频道列表（后台能加源，不用发版）
    func news(source: String, limit: Int = 40, offset: Int = 0) async throws -> NewsFeed {
        let s = source.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? source
        return try await get("/api/news?source=" + s + "&limit=\(limit)&offset=\(offset)", as: NewsFeed.self)
    }

    /* ---------------- 公众号（我们自己的） ---------------- */

    /// 通讯录 → 公众号：所有号 + 我关注没有
    func oaList() async throws -> [OAAccount] {
        struct P: Decodable { var accounts: [OAAccount]? }
        let p: P = try await get("/api/oa/list", as: P.self)
        return p.accounts ?? []
    }

    /// 某个号的主页：资料 + 历史文章
    func oaAccount(id: String) async throws -> OAAccountPage {
        let s = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        return try await get("/api/oa/account?id=" + s, as: OAAccountPage.self)
    }

    /// 文章详情（顺便让服务器把阅读数 +1）
    func oaArticle(id: String) async throws -> OAArticlePage {
        let s = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id
        return try await get("/api/oa/article?id=" + s, as: OAArticlePage.self)
    }

    /// 订阅 / 取消订阅（订阅以后会话列表里就有这个号了）
    @discardableResult
    func oaFollow(accountId: String, follow: Bool) async throws -> Bool {
        struct P: Decodable { var following: Bool? }
        let p: P = try await post("/api/oa/follow", ["accountId": accountId, "follow": follow], as: P.self)
        return p.following ?? follow
    }

    /// 我页下面那几行（同样是后台配的）
    func mePage() async throws -> [DiscoverItem] {
        let payload: DiscoverPayload = try await get("/api/me-page", as: DiscoverPayload.self)
        return payload.items.filter { $0.enabled != false }
    }

    /// 服务页整页配置（后台「服务页」模块配的，网页版和 App 共用一份）
    func serviceConfig() async throws -> ServiceConfig {
        try await get("/api/service", as: ServiceConfig.self)
    }

    /// 钱包页整页配置（后台「钱包页」模块配的；零钱那一行的数值是现算的余额）
    func walletConfig() async throws -> WalletConfig {
        try await get("/api/wallet", as: WalletConfig.self)
    }

    /// 安全分（微信「支付分」那套：550~850 · 身份特质 / 支付行为 / 守约历史）
    func securityScore() async throws -> CreditScore {
        try await get("/api/me/score", as: CreditScorePayload.self).score
    }

    /// 人脸比对口（2026-10-15）：活体过了以后把那一帧 + 实名信息传给后台，
    /// 后台人工比对（通过 / 驳回）；返回 true = 传上去了
    func faceSubmit(image: String, name: String, idCard: String, dist: Double? = nil) async -> Bool {
        guard !image.isEmpty else { return false }
        var body: [String: Any] = ["image": image, "name": name, "idCard": idCard]
        /* 与账号头像的特征距离（越小越像）：给后台人工比对当参考分 */
        if let d = dist { body["avatarDist"] = d }
        let ok = try? await request("POST", "/api/me/face", body: body)
        return ok != nil
    }

    /* ---------------- 人脸比对（后台，只有 ops 能调） ---------------- */

    /// 待比对 / 已比对的记录（带照片和实名信息）
    func opsFaces() async -> [FaceReviewRow] {
        struct Payload: Decodable { var items: [FaceReviewRow]? }
        guard let p: Payload = try? await get("/api/ops/faces", as: Payload.self) else { return [] }
        return p.items ?? []
    }

    /// 人工比对结论：pass = 通过（驳回传 false）
    @discardableResult
    func opsFaceReview(id: String, pass: Bool, note: String = "") async -> Bool {
        let r = try? await request("POST", "/api/ops/faces",
                                   body: ["id": id, "pass": pass, "note": note])
        return r != nil
    }

    /// 账单：这个人所有的转账 / 红包 / 充值提现 / 会员（wallet 页右上角「账单」用）
    /// - Parameter month: 形如 2026-10，不传 = 全部月份
    /// - Parameter limit: 最多要几条（服务端上限 200；收支统计要跨月做趋势，所以要得多一点）
    func bills(month: String? = nil, limit: Int? = nil) async throws -> BillsPayload {
        var qs: [String] = []
        if let m = month, !m.isEmpty {
            qs.append("month=" + m.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)
        }
        if let l = limit { qs.append("limit=\(max(1, min(200, l)))") }
        let path = "/api/bills" + (qs.isEmpty ? "" : "?" + qs.joined(separator: "&"))
        return try await get(path, as: BillsPayload.self)
    }

    /// 零钱页（钱包页点「零钱」进来）
    func balancePage() async throws -> BalancePageConfig {
        try await get("/api/balance-page", as: BalancePageConfig.self)
    }

    /// 设置/清除「状态」（对应后台配的那些状态）
    /// 「说点什么」那句可选文案（≤30 字）一起带上，和微信一样分两层存
    func setMood(_ item: StatusItem?, caption: String = "", fallbackColor: String = "") async {
        if let item = item {
            let label = (item.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let note = String(caption.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
            let own = MoodColor.clean(item.color)
            var c1 = own
            if c1.isEmpty { c1 = MoodColor.clean(fallbackColor) }
            var c2 = MoodColor.clean(item.color2)
            if c2.isEmpty { c2 = MoodColor.shift(c1, to: true) }
            await updateMe([
                "moodLabel": label,
                "moodCaption": note,
                "moodText": note.isEmpty ? label : note,
                "moodIcon": item.icon ?? "",
                "moodColor": c1,
                "moodColor2": c2
            ])
        } else {
            await updateMe(["moodText": "", "moodLabel": "", "moodCaption": "",
                            "moodIcon": "", "moodColor": "", "moodColor2": ""])
        }
    }

    /// 我的状态详情：还剩几个小时、谁看过（微信里点自己的状态看到的就是这些）
    func myStatus() async throws -> MyStatus {
        try await get("/api/me/status", as: MyStatus.self)
    }

    /// 结束（清除）我的状态
    func endMyStatus() async {
        _ = try? await request("POST", "/api/me/status", body: ["ended": true])
    }

    /// 图片压完再传：返回服务器上的 /uploads/xxx.jpg
    func upload(image: UIImage) async throws -> String {
        /* 长边 1280 / 画质 0.75：手机上看着和 1600@0.82 没差，体积只有三分之一左右。
           聊天气泡、朋友圈列表都是一屏好几张图，压小了翻起来才跟手。 */
        let data = image.resizedJPEG(maxSide: 1280, quality: 0.75)
        return try await uploadData(data)
    }

    /// 发图专用：和 upload / uploadOriginal 一样，但把**真正上传的那份字节**也返回出来。
    /// 调用方拿它按「下载过一次的图」的待遇写本地缓存（内存 + 磁盘 + 长期留底），
    /// 这样发出去的图自己也**秒出**、重开 App 也不用再下一遍。
    func uploadImageForSend(_ image: UIImage, original: Bool) async throws -> (url: String, data: Data) {
        /* 2026-10-14：压缩参数**保持原样**（用户明确要求"这个不要改"）。
           提速只靠"并行上传"，不动画质。 */
        let data = image.resizedJPEG(maxSide: original ? 1920 : 1280,
                                     quality: original ? 0.88 : 0.75)
        guard let data = data else { throw APIError.message("图片处理失败") }
        let url = try await uploadData(data)
        return (url, data)
    }

    /// 聊天背景：比头像清楚得多（长边 2048、画质 0.95）。
    /// 视频/大文件走二进制直传（不再 base64，少传 25%，手机上快一截）
    /// 给播放器的资源：带上鉴权头，让 AVPlayer 自己边下边播（服务器已支持 Range 分片）
    func streamingAsset(_ path: String) -> AVURLAsset? {
        guard let u = assetURL(path) else { return nil }
        let headers: [String: String] = token.isEmpty ? [:] : ["Authorization": "Bearer \(token)"]
        return AVURLAsset(url: u, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    }

    func uploadBinary(_ data: Data, mime: String) async throws -> String {
        guard let url = URL(string: base + "/api/upload/raw") else { throw APIError.message("服务器地址不正确") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (d, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.message("上传失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        return try Self.rawUploadURL(from: d)
    }

    /// 视频这种大文件：**从磁盘流式上传**（不整段读进内存，几十 MB 的视频也不会顶内存），
    /// 并且把真实上传进度回调出来 —— 聊天页那个「发送中」的转圈进度条就是靠它。
    func uploadBinaryFile(_ file: URL, mime: String,
                          skipTranscode: Bool = false,
                          onProgress: @escaping (Double) -> Void) async throws -> String {
        guard let url = URL(string: base + "/api/upload/raw") else { throw APIError.message("服务器地址不正确") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        /* 大视频 + 移动网络：给足时间，别传到一半自己超时 */
        req.timeoutInterval = 600
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        /* 告诉服务器「这条已经在手机上压好了，别再压一遍」——
           服务端跟着再压一遍要十几秒，用户感觉就是"发视频很慢"。 */
        if skipTranscode { req.setValue("1", forHTTPHeaderField: "x-chris-compressed") }
        let delegate = UploadProgressDelegate(onProgress)
        let (d, resp) = try await session.upload(for: req, fromFile: file, delegate: delegate)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.message("上传失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        return try Self.rawUploadURL(from: d)
    }

    /// /api/upload/raw 的返回值：可能直接是 {url}，也可能裹一层 {ok,data:{url}}
    private static func rawUploadURL(from d: Data) throws -> String {
        struct RawUpload: Decodable { var url: String? }
        if let parsed = try? JSONDecoder().decode(RawUpload.self, from: d),
           let u = parsed.url, !u.isEmpty { return u }
        struct Wrapper: Decodable { struct D: Decodable { var url: String? }; var data: D? }
        if let w = try? JSONDecoder().decode(Wrapper.self, from: d), let u = w.data?.url, !u.isEmpty { return u }
        throw APIError.message("上传返回异常")
    }

    /// 注意别设太大：一张 4800 万的相册原图直接按 4096 重绘会把内存打爆闪退。
    func uploadOriginal(image: UIImage) async throws -> String {
        // 「原图」也别给太大：1920 / 0.88 在手机上看不出区别，体积小一半以上
        let data = image.resizedJPEG(maxSide: 1920, quality: 0.88)
        return try await uploadData(data)
    }

    /// 朋友圈封面：比聊天背景还要大一点（长边 2560、画质 0.95）。
    /// 封面要能缩放拖动裁切，2048 放大后还是会糊，所以单独给一档。
    func uploadCover(image: UIImage) async throws -> String {
        let data = image.resizedJPEG(maxSide: 1920, quality: 0.88)
        return try await uploadData(data)
    }

    private func uploadData(_ data: Data?) async throws -> String {
        guard let data = data else {
            throw APIError.message("图片处理失败")
        }
        /* ⚠ 2026-10-12 用户「这个版本图片发出去有点慢，之前很快的」：
           以前图片是**塞进 JSON 里 base64** 传的 —— base64 本身要多传 33%，
           还要在手机上编码、在服务器上解码（两边都是白等的 CPU）。
           现在和视频/文件一样走**二进制直传**（/api/upload/raw），
           同样的图少传三分之一字节、少两次编解码，发图快一截。
           失败再退回老路（老服务器没有 /api/upload/raw 时照样能发）。 */
        if let url = try? await uploadRawJPEG(data) { return url }
        let b64 = data.base64EncodedString()
        let payload: UploadPayload = try await post("/api/upload",
                                                    ["dataUrl": "data:image/jpeg;base64," + b64,
                                                     "filename": "photo.jpg"],
                                                    as: UploadPayload.self)
        guard let url = payload.url else { throw APIError.message("上传失败") }
        return url
    }

    /// 图片二进制直传：POST /api/upload/raw（Content-Type: image/jpeg），返回服务器路径
    private func uploadRawJPEG(_ data: Data) async throws -> String {
        guard let url = URL(string: base + "/api/upload/raw") else {
            throw APIError.message("服务器地址不正确")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        /* 告诉服务器「这张已经在手机上按规格压好了」—— 服务器就不会再 spawn 一次 ffmpeg
           （它对 >300 万像素的图会自动缩一遍，那一下就是几百毫秒到 2 秒的卡顿） */
        req.setValue("1", forHTTPHeaderField: "x-chris-compressed")
        let (d, resp) = try await session.upload(for: req, from: data)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.message("上传失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        return try Self.rawUploadURL(from: d)
    }

    /// mentions：群里这条消息 @ 了谁（userId 列表）—— 服务端存下来，
    /// 被 @ 的人会话列表出「[有人@我]」、通知里也带这行字
    func send(chatId: String, kind: String, content: String, mentions: [String] = [],
              imgW: Int = 0, imgH: Int = 0, quote: [String: Any]? = nil) async throws -> Message? {
        var body: [String: Any] = ["kind": kind, "content": content]
        if !mentions.isEmpty { body["mentions"] = mentions }
        /* 图片宽高随消息一起带上：对面第一帧就按真实比例把气泡画好（骨架落位） */
        if imgW > 1, imgH > 1 { body["imgW"] = imgW; body["imgH"] = imgH }
        /* 引用卡片：结构化带给服务端（不是把「「谁：摘要」」拼在正文里） */
        if let q = quote, !q.isEmpty { body["quote"] = q }
        let payload: MessagePayload = try await post("/api/chats/\(chatId)/messages",
                                                     body,
                                                     as: MessagePayload.self)
        return payload.message
    }

    /// 带 clientId 的发送：离线重发时服务器按它去重（同一个 clientId 只落一条消息）
    func send(chatId: String, kind: String, content: String, mentions: [String] = [],
              clientId: String, imgW: Int = 0, imgH: Int = 0,
              quote: [String: Any]? = nil) async throws -> Message? {
        var body: [String: Any] = ["kind": kind, "content": content, "clientId": clientId]
        if !mentions.isEmpty { body["mentions"] = mentions }
        if imgW > 1, imgH > 1 { body["imgW"] = imgW; body["imgH"] = imgH }
        if let q = quote, !q.isEmpty { body["quote"] = q }
        let payload: MessagePayload = try await post("/api/chats/\(chatId)/messages",
                                                     body,
                                                     as: MessagePayload.self)
        return payload.message
    }

    func recall(chatId: String, messageId: String) async {
        _ = try? await request("POST", "/api/messages/\(messageId)/recall", body: ["chatId": chatId])
    }

    func likeMoment(id: String) async {
        _ = try? await request("POST", "/api/moments/\(id)/like", body: [:])
    }

    /* ---------------- 朋友圈「消息列表」（谁赞了/评论了我） ---------------- */

    func momentNotices() async -> (items: [MomentNotice], unread: Int) {
        guard let p = try? await get("/api/moments/notices", as: MomentNoticesPayload.self) else {
            return ([], 0)
        }
        return (p.items ?? [], p.unread ?? 0)
    }

    /// 点开这一页 = 看过了，小信封上的红点清掉
    func markMomentNoticesSeen() async {
        _ = try? await request("POST", "/api/moments/notices/seen", body: [:])
    }

    /// 打开朋友圈 = 看过了，「发现」上的红点清掉
    func markMomentsSeen() async {
        _ = try? await request("POST", "/api/moments/seen", body: [:])
    }

    func commentMoment(id: String, text: String, replyTo: String = "") async {
        var b: [String: Any] = ["content": text]
        /* 回复某条评论：带上那个人的 userId，服务端会存 replyTo，
           对方那边就显示成「A 回复 B：内容」（微信就是这样） */
        if !replyTo.isEmpty { b["replyTo"] = replyTo }
        _ = try? await request("POST", "/api/moments/\(id)/comments", body: b)
    }

    func deleteMoment(id: String) async {
        _ = try? await request("DELETE", "/api/moments/\(id)")
    }

    /// 置顶 / 取消置顶自己发的动态（置顶的固定排在朋友圈最上面，只能置顶一条）
    func pinMoment(id: String, pinned: Bool) async {
        _ = try? await request("POST", "/api/moments/\(id)/pin", body: ["pinned": pinned])
    }

    /// 删朋友圈评论（微信：点自己的评论 → 删除）
    func deleteMomentComment(momentId: String, commentId: String) async -> String? {
        do {
            _ = try await request("DELETE", "/api/moments/\(momentId)/comments/\(commentId)")
            return nil
        } catch {
            return (error as? APIError)?.errorDescription ?? "删除失败"
        }
    }

    /// 发朋友圈：谁可以看（public 公开 / private 仅自己 / partial 部分可见 / exclude 不给谁看）
    func postMoment(content: String, images: [String],
                    imageSizes: [String: [Int]] = [:],
                    video: String = "", videoCover: String = "",
                    videoSeconds: Int = 0, videoW: Int = 0, videoH: Int = 0,
                    visibility: String = "public",
                    visibleTo: [String] = [], hiddenFrom: [String] = [],
                    location: String = "") async throws {
        var body: [String: Any] = [
            "content": content, "images": images,
            "visibility": visibility, "visibleTo": visibleTo, "hiddenFrom": hiddenFrom,
            "location": location
        ]
        /* 每张图的宽高一起带上：列表那边就能按真实比例先画好框，
           不会再"先 4:3、加载完跳一下"（用户反馈的尺寸跳变） */
        if !imageSizes.isEmpty { body["imageSizes"] = imageSizes }
        if !video.isEmpty {
            body["video"] = video
            body["videoCover"] = videoCover
            body["videoSeconds"] = videoSeconds
            body["videoW"] = videoW
            body["videoH"] = videoH
        }
        _ = try await request("POST", "/api/moments", body: body)
    }

    func updateMe(_ fields: [String: Any]) async {
        _ = try? await request("PATCH", "/api/me", body: fields)
    }

    /// 和 updateMe 一样，但**把服务器那句话带回来**。
    /// 以前 updateMe 是 try?，服务器说"昵称不合格 / 手机号一年只能改一次"这种
    /// 整条 PATCH 会被拒，界面却照样提示"已保存" —— 用户看到的
    /// 「设置了地区/生日都没生效」十有八九就是它。
    func updateMeChecked(_ fields: [String: Any]) async throws {
        _ = try await request("PATCH", "/api/me", body: fields)
    }

    /// 新用户首次资料引导：头像 + 兴趣分类一次性保存，返回更新后的完整资料。
    func completeOnboarding(avatar: String, interests: [String]) async throws -> User {
        let any = try await request("PATCH", "/api/me", body: [
            "avatar": avatar,
            "interests": interests,
            "onboardingComplete": true
        ])
        let payload = try decode(any, as: LoginPayload.self)
        guard let user = payload.user else { throw APIError.message("保存资料失败") }
        return user
    }

    func addFriend(username: String, from: String = "") async throws {
        var body: [String: Any] = ["username": username]
        if !from.isEmpty { body["from"] = from }
        _ = try await request("POST", "/api/friends/request", body: body)
    }

    func rawUpload(_ body: [String: Any]) async throws -> (url: String, name: String, bytes: Int) {
        let payload: UploadPayload = try await post("/api/upload", body, as: UploadPayload.self)
        guard let url = payload.url else { throw APIError.message("上传失败") }
        return (url, payload.name ?? "", payload.bytes ?? 0)
    }

    func transfer(chatId: String, amount: Double, note: String,
                  method: String, password: String, face: Bool = false) async throws {
        _ = try await request("POST", "/api/pay/transfer", body: [
            "chatId": chatId,
            "amount": amount,
            "note": note,
            "method": method,
            "password": password,
            "face": face,
            /* 幂等键：这一笔的唯一编号。网络超时重发 / 用户连点，
               服务端看到同一个编号只会扣一次钱（接真钱必须的） */
            "requestId": UUID().uuidString
        ])
    }

    /* ---------------- 收付款（付款码 / 收款码，微信那套） ---------------- */

    /// 出一张付款码（18 位数字，60 秒有效；同一分钟内重复拉还是同一张）
    func payCode() async throws -> PayCodeInfo {
        try await post("/api/pay/code", [:], as: PayCodeInfo.self)
    }

    /// 我的收款码；amount > 0 就是「设置金额」那张（金额被服务器签名，改不了）
    func receiveCode(amount: Double) async throws -> PayCodeInfo {
        try await post("/api/pay/receive-code", ["amount": amount], as: PayCodeInfo.self)
    }

    /// 扫到的字符串先问一下服务器：这是谁的收付款码、金额多少
    func payResolve(text: String) async throws -> PayScanInfo {
        try await post("/api/pay/resolve", ["text": text], as: PayScanInfo.self)
    }

    /// 付款：钱当时到对方账上（商家收款即时到账）
    func payCollect(text: String, amount: Double, password: String, face: Bool = false) async throws -> PayCollectResult {
        try await post("/api/pay/collect", [
            "text": text, "amount": amount, "password": password, "face": face,
            "requestId": UUID().uuidString
        ], as: PayCollectResult.self)
    }

    func hasPayPassword() async -> Bool {
        guard let any = try? await request("GET", "/api/me/paypassword"),
              let dict = any as? [String: Any],
              let has = dict["has"] as? Bool else { return false }
        return has
    }

    /// 校验支付密码（转账确认用）
    func verifyPayPassword(_ password: String) async throws {
        _ = try await request("POST", "/api/me/paypassword/verify", body: ["password": password])
    }

    /// 设置 / 修改支付密码（6 位数字；已经设过的要带上原密码）
    func setPayPassword(_ password: String, current: String = "") async throws {
        var body: [String: Any] = ["password": password]
        if !current.isEmpty { body["current"] = current }
        _ = try await request("POST", "/api/me/paypassword", body: body)
    }

    /// 举报某人（后台「举报处理」里能看到）
    func report(userId: String, chatId: String, reason: String, content: String) async {
        _ = try? await request("POST", "/api/reports", body: [
            "targetUserId": userId,
            "chatId": chatId,
            "reason": reason,
            "content": content
        ])
    }
}

extension UIImage {
    /// 随图片消息一起带上服务器的「原始宽高」（只要比例对就行；上传时会按同一比例缩放）
    var sendPixelSize: (w: Int, h: Int) {
        (max(1, Int(size.width.rounded())), max(1, Int(size.height.rounded())))
    }

    /// 上传前压一下：长边最多 maxSide，JPEG 质量 quality
    func resizedJPEG(maxSide: CGFloat, quality: CGFloat) -> Data? {
        let long = max(size.width, size.height)
        var target = size
        if long > maxSide {
            let k = maxSide / long
            target = CGSize(width: size.width * k, height: size.height * k)
        }
        /* ⚠ 2026-10-12 用户「图片发出去有点慢」——真凶在这儿：
           服务器（checkImage）对**超过 300 万像素**的图会 spawnSync 跑一次 ffmpeg 再缩一遍，
           而 1280×2736 正好是 350 万像素 → 每张图上传完之后服务器还要卡几百毫秒到 2 秒
           （diag 实测：改二进制之前 200~500ms，之后 809ms / 2120ms，差别就是这次 ffmpeg）。
           所以客户端先自己压到 240 万像素以内（画质肉眼看不出差别），服务器就不会再动手，
           整个"发出去"的时间少掉那一大截。 */
        let pixels = target.width * target.height
        if pixels > 2_400_000 {
            let k = (2_400_000 / pixels).squareRoot()
            target = CGSize(width: (target.width * k).rounded(), height: (target.height * k).rounded())
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let out = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return out.jpegData(compressionQuality: quality)
    }
}
