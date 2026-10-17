/* 「界面打包进 App」专用：网页版（http/https）打开时这段代码什么都不做，直接返回。
   只有装成 App 打开（file://）时才会：
     1) 把相对地址 /api、/uploads 和 WebSocket 指到你电脑上的聊天服务器
     2) 用「令牌」登录（跨域带不了 Cookie），令牌存在 App 本地
     3) 给所有请求自动带上 Authorization: Bearer */
(function () {
  var proto = location.protocol;
  if (proto === 'http:' || proto === 'https:') return;

  var ORIGIN = 'http://192.168.2.7:5180';
  var WS_ORIGIN = 'ws://192.168.2.7:5180';
  var TOKEN_KEY = 'wx-app-token';

  function token() { try { return localStorage.getItem(TOKEN_KEY) || ''; } catch (e) { return ''; } }
  function saveToken(t) { try { if (t) localStorage.setItem(TOKEN_KEY, t); } catch (e) { /* 忽略 */ } }
  function isRel(u) { return typeof u === 'string' && u.charAt(0) === '/'; }

  /* App 里禁止双指缩放 / 双击放大：页面不再能放大缩小（网页版不受影响） */
  try {
    var vp = document.querySelector('meta[name="viewport"]');
    if (vp) vp.setAttribute('content', 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover');
    var st = document.createElement('style');
    st.textContent = 'html,body{touch-action:manipulation;-webkit-text-size-adjust:100%;text-size-adjust:100%;}' +
      'body{overscroll-behavior-y:none;}';
    (document.head || document.documentElement).appendChild(st);
  } catch (e) { /* 忽略 */ }

  /* 图片加载中 / 加载失败时，WebView 会画一个「?」占位，看着像坏了 —— 一律藏掉 */
  try {
    document.addEventListener('error', function (e) {
      var t = e.target;
      if (t && t.tagName === 'IMG') t.style.visibility = 'hidden';
    }, true);
    document.addEventListener('load', function (e) {
      var t = e.target;
      if (t && t.tagName === 'IMG') t.style.visibility = '';
    }, true);
  } catch (e) { /* 忽略 */ }

  function withAuth(init) {
    var o = Object.assign({}, init || {});
    var h = Object.assign({}, o.headers || {});
    var t = token();
    if (t && !h.Authorization && !h.authorization) h.Authorization = 'Bearer ' + t;
    o.headers = h;
    return o;
  }

  /* 登录/注册的响应里带着 token（服务端专门为 App 加的）。
     这里必须「先存好令牌再把响应交给页面」，否则紧接着的 /api/me 会跑到存令牌前面去（会 401）。 */
  function capture(res, url) {
    /* 退出登录：服务端会把 Cookie 清掉，但 App 里用的是本地令牌，
       这里也要一起清掉，否则退出后又自动登录、回不到登录页。 */
    if (/\/api\/logout/.test(String(url))) {
      try { localStorage.removeItem(TOKEN_KEY); } catch (e) { /* 忽略 */ }
    }
    if (!/\/api\/(login|register|phone)/.test(String(url))) return res;
    try {
      return res.clone().json().then(function (d) {
        if (d && d.data && d.data.token) saveToken(d.data.token);
        return res;
      }).catch(function () { return res; });
    } catch (e) { return res; }
  }

  var f = window.fetch;
  if (f) {
    window.fetch = function (input, init) {
      var url = isRel(input) ? ORIGIN + input : input;
      return f.call(this, url, withAuth(init)).then(function (res) { return capture(res, url); });
    };
  }

  var xopen = XMLHttpRequest.prototype.open;
  var xsend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    var rest = Array.prototype.slice.call(arguments, 2);
    if (isRel(url)) url = ORIGIN + url;
    return xopen.apply(this, [method, url].concat(rest));
  };
  XMLHttpRequest.prototype.send = function () {
    var t = token();
    if (t) { try { this.setRequestHeader('Authorization', 'Bearer ' + t); } catch (e) { /* 忽略 */ } }
    return xsend.apply(this, arguments);
  };

  var NativeWS = window.WebSocket;
  if (NativeWS) {
    var WS = function (url, protocols) {
      var path = String(url).replace(/^wss?:\/\/[^/]*/i, '');
      if (!path) path = '/';
      var t = token();
      var full = WS_ORIGIN + path + (t ? (path.indexOf('?') >= 0 ? '&' : '?') + 'token=' + encodeURIComponent(t) : '');
      return protocols === undefined ? new NativeWS(full) : new NativeWS(full, protocols);
    };
    WS.prototype = NativeWS.prototype;
    window.WebSocket = WS;
  }

  /* 头像、聊天背景、朋友圈封面这些也补上前缀。
     注意：JS 里写的是 url("/uploads/x.jpg")（带引号），所以正则要能兼容引号，
     不然封面背景图会去 app://localhost/uploads/... 找，直接 404 不显示。 */
  function fix() {
    var imgs = document.querySelectorAll('img[src^="/"]');
    for (var i = 0; i < imgs.length; i++) {
      var s = imgs[i].getAttribute('src');
      if (s && s.charAt(0) === '/') imgs[i].src = ORIGIN + s;
    }
    var styled = document.querySelectorAll('[style*="url("]');
    for (var k = 0; k < styled.length; k++) {
      var st = styled[k].getAttribute('style') || '';
      if (st.indexOf('/uploads/') < 0 || st.indexOf(ORIGIN) >= 0) continue;
      styled[k].setAttribute('style', st.replace(/url\((["']?)(\/uploads\/[^"')]+)\1\)/g, 'url($1' + ORIGIN + '$2$1)'));
    }
  }
  document.addEventListener('DOMContentLoaded', fix);
  /* 这里原来是 setInterval(fix, 1500)：每 1.5 秒把整个页面的 <img> 和带 url() 的元素
     全扫一遍，聊天记录多了以后手机会一卡一卡的。
     改成：只在有新节点时补一次（MutationObserver），另外再留一个 8 秒的兜底，
     给那些「先设了 src/style 之后才插进 DOM」的情况兜底。 */
  var fixTimer = 0;
  function scheduleFix() {
    if (fixTimer) return;
    fixTimer = setTimeout(function () { fixTimer = 0; fix(); }, 120);
  }
  try {
    if (window.MutationObserver) {
      new MutationObserver(scheduleFix).observe(document.documentElement, { childList: true, subtree: true });
    }
  } catch (e) { /* 忽略 */ }
  setInterval(fix, 20000);
})();
