import SwiftUI
import WebKit

/* ============================================================
   小游戏「好友排名」（每个游戏都有，不用改游戏本身）

   运行时往页面里注一层 JS：
   · **自动报分**：盯着 localStorage 里那些 `*_best`（跳一跳 jj_best、2048 g2048_best…），
     一存就把分数报给服务器（POST /api/games/score，只涨不跌）
   · **排名面板**：顶部那颗 🏆 调 window.chrisRank.show()，拉
     GET /api/games/rank?game=xxx（我 + 我的好友，按最高分排）画一张底部弹层
   ============================================================ */

/// 让外面能拿到正在显示的那个 webview（顶栏那颗 🏆 要往里打 JS）
final class WebBox: ObservableObject {
    weak var web: WKWebView?
}

/* ============================================================
   ⚠ 为什么排行榜以前一直不生效：

   小游戏是**先下到本机再跑**的（file:// 打开的），原来那层 JS 里是直接
   `fetch('https://43.242.194.89/api/games/score')` —— 这条路走不通：
     · 网页是 file:// 起源，属于跨域；
     · 更要命的是 App 连的是**IP + 自签证书**，WKWebView 不认这个证书，
       请求在 TLS 那一步就断了（游戏文件要下到本机也是同一个原因）。
   而 fetch 是 `.catch(function(){})` 静默吃掉的，所以"报分/拉榜都做了，就是没反应"。

   现在改成**原生桥**：网页只喊一声
     window.webkit.messageHandlers.chrisRank.postMessage({action:'score'|'rank', ...})
   真正发请求的是原生这边（走 App 自己那套网络栈，证书是放过的），
   拉完榜单再把 JSON 塞回网页里画（chrisRank.render(json)）。
   JS 里保留 fetch 兜底：万一哪天桥没挂上，老的逻辑还能跑。
   ============================================================ */

/// 网页 → 原生 的那根线（WKScriptMessageHandler）
final class RankBridge: NSObject, WKScriptMessageHandler {
    /// 报分：游戏标识 + 分数
    var onScore: ((String, Int) -> Void)?
    /// 拉榜单：游戏标识 + 回调（回的是服务器那段 JSON 字符串，空串 = 失败）
    var onRank: ((String, @escaping (String) -> Void) -> Void)?
    /// 棋牌大厅那根线（同一个宿主，另一个 handler 名）
    let room = RoomBridge()
    weak var web: WKWebView?

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let action = (body["action"] as? String) ?? ""
        let game = (body["game"] as? String) ?? ""
        if action == "score" {
            let n = (body["score"] as? NSNumber)?.intValue ?? 0
            onScore?(game, n)
        } else if action == "rank" {
            onRank?(game) { [weak self] json in
                guard !json.isEmpty else { return }
                DispatchQueue.main.async {
                    self?.web?.evaluateJavaScript("window.chrisRank && window.chrisRank.render(\(json));")
                }
            }
        }
    }
}

/* 棋牌大厅那根线：网页里走了一步 → 原生拿去发给同桌的人 */
final class RoomBridge: NSObject, WKScriptMessageHandler {
    var onMove: (([String: Any]) -> Void)?

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        guard (body["action"] as? String) == "move" else { return }
        if let mv = body["move"] as? [String: Any] { onMove?(mv) }
    }
}

func chrisRankJs(game: String, token: String, base: String) -> String {
    let g = game.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let t = token.replacingOccurrences(of: "\"", with: "\\\"")
    let b = base.replacingOccurrences(of: "\"", with: "\\\"")
    return """
    (function () {
      if (window.chrisRank) return;
      var GAME = "\(g)", TOKEN = "\(t)", BASE = "\(b)";
      function abs(u) { return /^https?:/i.test(u || '') ? u : (BASE + ((u || '').charAt(0) === '/' ? u : '/' + (u || ''))); }
      function report(n) {
        n = Math.floor(Number(n) || 0);
        if (!(n > 0)) return;
        /* 先走原生桥（网页是本地文件，自己发请求发不出去 —— 见上面那段说明） */
        if (bridge({ action: 'score', game: GAME, score: n })) return;
        fetch(abs('/api/games/score'), {
          method: 'POST',
          headers: { 'Authorization': 'Bearer ' + TOKEN, 'Content-Type': 'application/json' },
          body: JSON.stringify({ game: GAME, score: n })
        }).catch(function () { });
      }
      function hide() {
        var el = document.getElementById('__chris_rank');
        if (el) el.remove();
        if (window.__crTimer) { clearInterval(window.__crTimer); window.__crTimer = null; }
      }
      /* 原生桥：网页 → App（真正发请求的是 App 自己，证书/跨域都不是问题） */
      function bridge(msg) {
        try {
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.chrisRank) {
            window.webkit.messageHandlers.chrisRank.postMessage(msg);
            return true;
          }
        } catch (e) { }
        return false;
      }
      function show() {
        hide();
        if (bridge({ action: 'rank', game: GAME })) return;
        fetch(abs('/api/games/rank?game=' + encodeURIComponent(GAME)), { headers: { 'Authorization': 'Bearer ' + TOKEN } })
          .then(function (r) { return r.json(); })
          .then(function (j) { paint(j); })
          .catch(function () { });
      }
      /* 画榜单（原生桥拿回来的那段 JSON 也走这里） */
      function paint(j) {
        hide();
        /* 两种来源都要认：原生桥直接给 data，JS 兜底的 fetch 给的是 {ok,data} */
        var d = (j && j.data) ? j.data : (j || {});
        var list = d.list || [];
            var rows = list.map(function (x) {
              var medal = x.rank === 1 ? '🥇' : (x.rank === 2 ? '🥈' : (x.rank === 3 ? '🥉' : (x.rank + '')));
              return '<div class="__cr_row' + (x.me ? ' me' : '') + '">'
                + '<span class="__cr_rk">' + medal + '</span>'
                + '<img src="' + abs(x.avatar || '') + '" onerror="this.style.visibility=\\'hidden\\'">'
                + '<span class="__cr_nm">' + (x.name || '') + '</span>'
                + '<span class="__cr_sc">' + (x.score || 0) + '</span></div>';
            }).join('');
            var el = document.createElement('div');
            el.id = '__chris_rank';
            el.innerHTML = '<style>'
              + '#__chris_rank{position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:999999;display:flex;align-items:flex-end}'
              + '#__chris_rank .box{width:100%;max-height:72%;background:#1C1C1E;border-radius:16px 16px 0 0;padding:14px 0 10px;overflow:auto;font-family:-apple-system,"PingFang SC",sans-serif}'
              + '#__chris_rank h3{color:#fff;font-size:16px;margin:0 0 10px;text-align:center;font-weight:600}'
              + '#__chris_rank .__cr_row{display:flex;align-items:center;gap:10px;padding:9px 18px;color:#fff;font-size:15px}'
              + '#__chris_rank .__cr_row.me{background:rgba(62,211,127,.16)}'
              + '#__chris_rank .__cr_rk{width:26px;text-align:center;font-size:13px;color:#9a9a9a}'
              + '#__chris_rank img{width:30px;height:30px;border-radius:15px;background:#333}'
              + '#__chris_rank .__cr_nm{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}'
              + '#__chris_rank .__cr_sc{color:#3ED37F;font-weight:600}'
              + '#__chris_rank .__cr_my{text-align:center;color:#9a9a9a;font-size:12.5px;padding:8px}'
              + '#__chris_rank .__cr_btn{display:block;margin:10px auto 4px;padding:9px 26px;border-radius:20px;background:#3ED37F;color:#fff;border:0;font-size:15px}'
              + '</style><div class="box"><h3>好友排名</h3>'
              + (rows || '<div class="__cr_my">还没有人玩过，你先来一局</div>')
              + '<div class="__cr_my">我的名次：第 ' + (d.myRank || '-') + ' 名 · 最高 ' + (d.myScore || 0) + ' 分</div>'
              + '<button class="__cr_btn" onclick="chrisRank.hide()">关闭</button></div>';
            el.addEventListener('click', function (e) { if (e.target === el) hide(); });
            document.body.appendChild(el);
            /* 榜单开着的时候每 5 秒自己刷一次：好友那边刚打完一把，这边数字会跟着跳
               （用户说"排名是死的不会跳数字"） */
            if (window.__crTimer) clearInterval(window.__crTimer);
            window.__crTimer = setInterval(function () {
              if (!document.getElementById('__chris_rank')) { hide(); return; }
              if (bridge({ action: 'rank', game: GAME })) return;
              fetch(abs('/api/games/rank?game=' + encodeURIComponent(GAME)), { headers: { 'Authorization': 'Bearer ' + TOKEN } })
                .then(function (r) { return r.json(); })
                .then(function (j2) { paint(j2); })
                .catch(function () { });
            }, 5000);
      }
      /* 自动报分：页面自己往 localStorage 存的最高分（*_best）一存就报上去 */
      try {
        var orig = localStorage.setItem.bind(localStorage);
        localStorage.setItem = function (k, v) {
          orig(k, v);
          try {
            /* ⚠ 以前只认 *_best / score / high，项目里那些游戏存的是 'best'、'junqi_wins'、
               'ddz_win' 这种 —— 全都匹配不上，于是**一个分都报不上去**，
               好友排名自然"永远不动"（用户说的"是死的不会跳数字"）。现在放宽：
               只要 key 里带 best/score/high/record/max/win/rank 就报。 */
            if (/(best|score|high|record|max|win|rank|combo)/i.test(k)) {
              var n = parseInt(String(v).replace(/[^0-9]/g, ''), 10);
              if (n > 0) report(n);
            }
          } catch (e) { }
        };
        Object.keys(localStorage).forEach(function (k) {
          if (/(best|score|high|record|max|win|rank|combo)/i.test(k)) {
            var n = parseInt(String(localStorage.getItem(k)).replace(/[^0-9]/g, ''), 10);
            if (n > 0) report(n);
          }
        });
      } catch (e) { }

      /* ===== 微信那套「关系链数据」的兼容层 =====
         项目的游戏（斗地主 / 三国杀 / 四国军棋…）用 wx.setUserCloudStorage 上报分数、
         wx.getFriendCloudStorage 拉好友榜。这里把它们接到我们服务器上，
         游戏里那个排行榜就能真的动起来（分数变了会立刻重报）。 */
      try {
        var wxo = window.wx || (window.wx = {});
        var kvs = {};
        wxo.setUserCloudStorage = function (o) {
          o = o || {};
          (o.KVDataList || []).forEach(function (kv) {
            if (!kv || !kv.key) return;
            kvs[kv.key] = String(kv.value == null ? '' : kv.value);
            var n = parseInt(String(kv.value).replace(/[^0-9]/g, ''), 10);
            if (n > 0) report(n);
          });
          if (o.success) try { o.success({}); } catch (e) {}
        };
        wxo.getUserCloudStorage = function (o) {
          o = o || {};
          var list = (o.keyList || Object.keys(kvs)).map(function (k) { return { key: k, value: kvs[k] || '0' }; });
          if (o.success) try { o.success({ KVDataList: list }); } catch (e) {}
        };
        wxo.getFriendCloudStorage = function (o) {
          o = o || {};
          fetch(abs('/api/games/rank?game=' + encodeURIComponent(GAME)), { headers: { 'Authorization': 'Bearer ' + TOKEN } })
            .then(function (r) { return r.json(); })
            .then(function (j) {
              var d = (j && j.data) ? j.data : (j || {});
              var list = (d.list || []).map(function (x) {
                return {
                  avatarUrl: abs(x.avatar || ''),
                  nickname: x.name || '',
                  openid: x.id || '',
                  KVDataList: [{ key: 'score', value: String(x.score || 0) }]
                };
              });
              if (o.success) o.success({ data: list });
            }).catch(function () { if (o.fail) o.fail({}); });
        };
        /* 开放数据域常用的那几个，给个空壳免得游戏报错 */
        if (!wxo.onMessage) wxo.onMessage = function () {};
        if (!wxo.postMessage) wxo.postMessage = function () {};
        if (!wxo.getUserInfo) {
          wxo.getUserInfo = function (o) {
            o = o || {};
            var me = (window.chrisMe || {});
            if (o.success) o.success({ userInfo: { nickName: me.name || '我', avatarUrl: me.avatar || '' } });
          };
        }
      } catch (e) { }
      window.chrisRank = { report: report, show: show, hide: hide, render: paint, game: GAME };
    })();
    """
}
