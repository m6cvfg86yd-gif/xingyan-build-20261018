import SwiftUI

/* ============================================================
   服务页那套图标（和服务器 data/icon-defaults.json 里的 svc.* 一模一样）

   正常情况图标是从后台下发的（/api/service 里带着 svg，后台换成自定义的也生效），
   这里只是「拉不到配置 / 服务器还没升级」时的兜底，保证页面不会开天窗。
   描边风格和发现页、我页那套 i.* 一致：fill=none + stroke=currentColor。
   ============================================================ */

enum SvcIcon {
    static let map: [String: String] = [
        "svc.pay": #"<svg data-key="svc.pay" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.4v11.2M8 6.4v11.2M12 6.4v11.2M16 6.4v11.2M20 6.4v11.2"/></svg>"#,
        "svc.wallet": #"<svg data-key="svc.wallet" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="6.2" width="18" height="12.6" rx="3"/><path d="M15.2 12.5h3.2"/></svg>"#,
        "svc.creditcard": #"<svg data-key="svc.creditcard" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="2.8" y="6" width="18.4" height="12" rx="2.6"/><path d="M2.8 10.6h18.4"/></svg>"#,
        "svc.fund": #"<svg data-key="svc.fund" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4 16.8l4.4-4.6 3.2 3 7.4-7.9"/><path d="M15.4 7.3h3.8v3.8"/></svg>"#,
        "svc.insure": #"<svg data-key="svc.insure" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3.4l7 2.6v5.4c0 4.4-2.9 7.6-7 9.2-4.1-1.6-7-4.8-7-9.2V6z"/><path d="M8.8 12.1l2.2 2.2 4.2-4.4"/></svg>"#,
        "svc.phone": #"<svg data-key="svc.phone" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="7" y="2.8" width="10" height="18.4" rx="2.6"/><path d="M10.8 18.4h2.4"/><path d="M12 7.2v5.2M9.8 8.6l2.2 2.4 2.2-2.4M10.2 11.4h3.6"/></svg>"#,
        "svc.utility": #"<svg data-key="svc.utility" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M13.4 3L6.6 13.4h4.2l-1.2 7.6 7.4-10.6h-4.4z"/></svg>"#,
        "svc.qcoin": #"<svg data-key="svc.qcoin" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="11.2" r="7.4"/><path d="M13.6 15.6l2.6 3.2"/></svg>"#,
        "svc.city": #"<svg data-key="svc.city" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M3.6 20.4V9.6h5.2v10.8M8.8 20.4V4.4h6.4v16M15.2 20.4v-7.6h5.2v7.6"/><path d="M4.6 20.4h14.8"/></svg>"#,
        "svc.charity": #"<svg data-key="svc.charity" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20.4S3.8 15.4 3.8 9.9A4.4 4.4 0 0 1 12 7.5a4.4 4.4 0 0 1 8.2 2.4c0 5.5-8.2 10.5-8.2 10.5z"/></svg>"#,
        "svc.health": #"<svg data-key="svc.health" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M9.6 3.6h4.8v6h6v4.8h-6v6H9.6v-6h-6V9.6h6z"/></svg>"#,
        "svc.travel": #"<svg data-key="svc.travel" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4.2 15.2h15.6M5.6 15.2l1.4-4.6c.3-1 1.2-1.7 2.3-1.7h5.4c1.1 0 2 .7 2.3 1.7l1.4 4.6"/><circle cx="7.8" cy="17.8" r="1.6"/><circle cx="16.2" cy="17.8" r="1.6"/></svg>"#,
        "svc.train": #"<svg data-key="svc.train" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="5.2" y="3.4" width="13.6" height="13.6" rx="3"/><path d="M5.2 11.4h13.6"/><path d="M9.2 20.6l1.6-3.6M14.8 20.6l-1.6-3.6"/></svg>"#,
        "svc.hotel": #"<svg data-key="svc.hotel" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M3.6 18.8V7.6M3.6 14.6h16.8v4.2M3.6 12.2h6a2.6 2.6 0 0 1 2.6 2.6"/><circle cx="6.9" cy="10.5" r="1.9"/></svg>"#,
        "svc.didi": #"<svg data-key="svc.didi" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4.2 15.4h15.6M5.6 15.4l1.4-4.6c.3-1 1.2-1.7 2.3-1.7h5.4c1.1 0 2 .7 2.3 1.7l1.4 4.6"/><circle cx="7.8" cy="18" r="1.6"/><circle cx="16.2" cy="18" r="1.6"/><path d="M9.8 6.4h4.4"/></svg>"#,
        "svc.jd": #"<svg data-key="svc.jd" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M5.4 8.4h13.2l1.1 11.2H4.3z"/><path d="M9 8.4V6.6a3 3 0 0 1 6 0v1.8"/></svg>"#,
        "svc.meituan": #"<svg data-key="svc.meituan" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4 11.6h16a8 8 0 0 1-8 7.8 8 8 0 0 1-8-7.8z"/><path d="M8.6 8.4l1.4-3.4M15.4 8.4l1.4-3.4"/></svg>"#,
        "svc.movie": #"<svg data-key="svc.movie" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="3.4" y="6.6" width="17.2" height="13" rx="2.6"/><path d="M3.4 11h17.2"/><path d="M8.6 6.6l-2 4.4M13.4 6.6l-2 4.4M18.2 6.6l-2 4.4"/></svg>"#,
        "svc.pdd": #"<svg data-key="svc.pdd" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="3.6" y="8.8" width="16.8" height="11.2" rx="2"/><path d="M3.6 12.4h16.8M12 8.8v11.2"/><path d="M12 8.8S10.8 4.2 8.4 4.2a2.2 2.2 0 0 0 0 4.6M12 8.8s1.2-4.6 3.6-4.6a2.2 2.2 0 0 1 0 4.6"/></svg>"#
    ]

    /// 拿图标：优先用后台下发的 svg，没有就用内置这套
    static func markup(_ key: String?, _ served: String?) -> String {
        if let served = served, !served.isEmpty { return served }
        if let key = key, let hit = map[key] { return hit }
        return ""
    }
}

/* 服务器联系不上 / 还没升级时的兜底：内容和参考图一致，图标走上面那套内置的 */
enum ServiceFallback {
    static let groups: [(String, [(String, String, String)])] = [
        ("金融理财", [("信用卡还款", "svc.creditcard", "#19A47A"), ("理财通", "svc.fund", "#10AEFF"), ("保险服务", "svc.insure", "#FA9D3B")]),
        ("生活服务", [("手机充值", "svc.phone", "#1180E0"), ("生活缴费", "svc.utility", "#19A47A"), ("Q币充值", "svc.qcoin", "#10AEFF"),
                   ("城市服务", "svc.city", "#19A47A"), ("腾讯公益", "svc.charity", "#FA5151"), ("医疗健康", "svc.health", "#FA9D3B")]),
        ("交通出行", [("出行服务", "svc.travel", "#1180E0"), ("火车票机票", "svc.train", "#19A47A"), ("酒店民宿", "svc.hotel", "#FA9D3B"),
                   ("滴滴出行", "svc.didi", "#19A47A")]),
        ("购物消费", [("京东购物", "svc.jd", "#FA5151"), ("美团外卖", "svc.meituan", "#FA9D3B"), ("电影演出", "svc.movie", "#1180E0"),
                   ("拼多多", "svc.pdd", "#FA5151")])
    ]
}

/* ============================================================
   钱包页的图标 + 兜底内容（和服务器 data/icon-defaults.json 里的 svc.w* 一致）
   正常情况下这些都从 /api/wallet 下发，这里只是服务器连不上/还没升级时不至于白屏。
   ============================================================ */

enum WalletIcon {
    static let map: [String: String] = [
        "svc.wcoin": #"<svg data-key="svc.wcoin" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.6"/><path d="M12 7.4v9M9.6 9.8l2.4 2.6 2.4-2.6M9.8 12.6h4.4"/></svg>"#,
        "svc.wbiz": #"<svg data-key="svc.wbiz" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9.6h16v9.6H4z"/><path d="M3.2 9.6l1.6-4.8h14.4l1.6 4.8"/><path d="M9.6 19.2v-5.4h4.8v5.4"/></svg>"#,
        "svc.wfund": #"<svg data-key="svc.wfund" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.6"/><path d="M8.4 13.6l2.6-2.8 2.2 2 2.6-3"/><path d="M14.2 9.8h2v2"/></svg>"#,
        "svc.wcard": #"<svg data-key="svc.wcard" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="6.2" width="18" height="12.6" rx="2.6"/><path d="M3 10.8h18"/><path d="M6.4 15.4h4"/></svg>"#,
        "svc.wfamily": #"<svg data-key="svc.wfamily" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><circle cx="9.2" cy="9.4" r="3"/><path d="M3.8 19.4c0-3 2.4-5.2 5.4-5.2s5.4 2.2 5.4 5.2"/><path d="M15.4 7.4a2.6 2.6 0 0 1 0 5.2M17.4 19.4c0-2.2-.9-4-2.2-5.2"/></svg>"#,
        "svc.wscore": #"<svg data-key="svc.wscore" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3.6l7 2.6v5.2c0 4.3-2.9 7.4-7 8.8-4.1-1.4-7-4.5-7-8.8V6.2z"/><path d="M9 12l2.2 2.2 4-4.2"/></svg>"#,
        "svc.wservice": #"<svg data-key="svc.wservice" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4.4 14.6v-2.4a7.6 7.6 0 0 1 15.2 0v2.4"/><rect x="2.6" y="13.4" width="3.6" height="5.4" rx="1.6"/><rect x="17.8" y="13.4" width="3.6" height="5.4" rx="1.6"/><path d="M19.6 18.8v.6a2.6 2.6 0 0 1-2.6 2.6h-2.4"/></svg>"#
    ]

    static func markup(_ key: String?, _ served: String?) -> String {
        if let served = served, !served.isEmpty { return served }
        if let key = key, let hit = map[key] { return hit }
        return ""
    }
}

enum WalletFallback {
    /// 拉不到 /api/wallet 时用这份（内容和参考图一致；零钱那行的数值由视图现填余额）
    static func config(balance: Double) -> WalletConfig {
        func item(_ id: String, _ label: String, _ key: String, _ color: String,
                  value: String? = nil, note: String? = nil, kind: String? = nil, action: String = "soon") -> WalletItem {
            WalletItem(id: id, label: label, value: value, valueKind: kind, note: note,
                       icon: key, svg: WalletIcon.markup(key, nil), color: color, action: action, enabled: true)
        }
        let card1 = WalletGroup(id: "wg1", enabled: true, items: [
            item("w01", "零钱", "svc.wcoin", "#F5C000", value: "¥" + moneyFmt(balance), kind: "balance", action: "balance"),
            item("w02", "经营账户", "svc.wbiz", "#F5C000", value: "¥0.00"),
            item("w03", "零钱通", "svc.wfund", "#F5C000", note: "收益率 1.01%"),
            item("w04", "银行卡", "svc.wcard", "#1180E0", action: "card"),
            item("w05", "亲属卡", "svc.wfamily", "#FA9D3B")
        ])
        let card2 = WalletGroup(id: "wg2", enabled: true, items: [
            item("w06", "支付分", "svc.wscore", "#2BC46E"),
            item("w07", "客服中心", "svc.wservice", "#19A47A", action: "service")
        ])
        let foot = [
            WalletFoot(id: "wf1", label: "身份信息", action: "identity", enabled: true),
            WalletFoot(id: "wf2", label: "支付设置", action: "settings", enabled: true)
        ]
        return WalletConfig(title: "钱包",
                            right: WalletRight(label: "账单", action: "bills"),
                            groups: [card1, card2],
                            footer: foot,
                            style: WalletStyle(),
                            balance: balance)
    }
}
