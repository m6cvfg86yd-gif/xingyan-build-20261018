(function () {
  'use strict';
  /* 网页版（浏览器打开）自动补上 iPhone 的状态栏 + Home 条高度：
     左边是微信手机截图、右边是浏览器里的网页时，整页会比微信高/矮一截，
     补上这层后导航、搜索框、每一行的位置和手机上（App 里）完全对得上。
     App 里用的是真机安全区 env(safe-area-inset-*)，不套这一层。 */
  (function webSafeArea() {
    var proto = location.protocol;
    if (proto !== 'http:' && proto !== 'https:') return;
    /* 再确认一下真的没有安全区：用一个探针读 env(safe-area-inset-top)。
       读出来是 0（浏览器里的常态）才补；万一 App 是用 http 打开的、
       本来就有 59px 安全区，就不要再叠一层。 */
    try {
      var probe = document.createElement('div');
      probe.style.cssText = 'position:fixed;left:-9999px;top:0;width:1px;height:1px;' +
        'padding-top:env(safe-area-inset-top,0px);';
      (document.body || document.documentElement).appendChild(probe);
      var inset = probe.getBoundingClientRect().height - 1;
      probe.parentNode.removeChild(probe);
      if (inset > 4) return;
    } catch (e) { /* 读不到就按浏览器处理 */ }
    var de = document.documentElement;
    if (de) de.classList.add('web-safe');
  })();
  var API = '/api';
  var S = {
    me: null, chats: [], friends: [], messages: {}, activeChat: null,
    moments: [], momentUnread: 0, online: {}, tab: 'chats', plusItems: null, gifts: null,
    stickerPacks: null, stickerTp: { provider: 'off', enabled: false }, stickerTab: 0
  };
  var socket = null;
  /* 附近的人：上一次拿到的定位（同一会话里不用重复定位）+ 当前筛选项 */
  var nearbyPos = null;
  var nearbyGender = 'all';
  /* 视频号 / 直播 / 游戏 的共享状态：放最外层，长连接回调里也要用 */
  var feed = [];
  var liveRooms = [], liveRoom = null;
  var games = [];

  /* ---------------- 外观（默认深色，和参考图一致） ---------------- */
  function applyTheme(mode) {
    var m = mode || 'dark';
    try { localStorage.setItem('wx-mobile-theme', m); } catch (e) { }
    var light = m === 'light';
    document.documentElement.setAttribute('data-theme', light ? 'light' : 'dark');
    var hint = document.getElementById('themeHint');
    if (hint) hint.textContent = light ? '浅色' : '深色';
    /* 切深浅色后，后台配的颜色（浅色|深色两份）要跟着重算一次 */
    if (typeof applyUiVars === 'function') applyUiVars();
  }
  function currentTheme() {
    try { return localStorage.getItem('wx-mobile-theme') || 'dark'; } catch (e) { return 'dark'; }
  }
  applyTheme(currentTheme());

  var $ = function (id) { return document.getElementById(id); };
  var esc = function (v) {
    return String(v == null ? '' : v)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  };
  var initials = function (n) { return String(n || '?').trim().slice(0, 1); };
  /** 消息里的网址变成可点的链接（点一下复制，方便去淘宝/天猫打开） */
  function linkify(text) {
    return esc(text).replace(/(https?:\/\/[^\s"'<>）)]+)/g, function (u) {
      return '<a class="wx-link" href="' + u + '" target="_blank" rel="noopener">' + u + '</a>';
    });
  }
  /* 点消息里的链接：先试「直接打开对应的 App」（淘宝/天猫），打不开再在当前页打开网页版 */
  function openOutside(url) {
    if (!url) return;
    var host = (url.match(/^https?:\/\/([^/]+)/) || [])[1] || '';
    var scheme = /taobao/i.test(host) ? 'taobao://' : (/tmall/i.test(host) ? 'tmall://' : '');
    var started = Date.now();
    var openWeb = function () { try { location.href = url; } catch (e) { window.open(url, '_blank'); } };
    if (!scheme) { openWeb(); return; }
    toast('正在打开' + (/taobao/i.test(host) ? '淘宝' : '天猫') + '…');
    var fallback = setTimeout(function () {
      if (document.visibilityState === 'visible' && Date.now() - started > 1200) openWeb();
    }, 1600);
    document.addEventListener('visibilitychange', function () { if (document.hidden) clearTimeout(fallback); }, { once: true });
    try { location.href = scheme + url.replace(/^https?:\/\//, ''); } catch (e) { }
  }
  /** 头像/图片统一带 lazy + async，长列表滑动不掉帧 */
  var imgTag = function (src, cls) {
    return '<img src="' + esc(src) + '"' + (cls ? ' class="' + cls + '"' : '') + ' loading="lazy" decoding="async" alt="">';
  };

  function api(path, options) {
    var opts = options || {};
    opts.headers = Object.assign({ 'Content-Type': 'application/json' }, opts.headers || {});
    return fetch(API + path, opts).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (body) {
        if (!res.ok || body.ok === false) throw new Error(body.error || ('请求失败 ' + res.status));
        return body.data;
      });
    });
  }

  var toastTimer = null;
  /* ---------------------------------------------------------- 相册直连（App 里才走这条）
     网页版的 <input type=file> 在 iPhone 上一定会先弹苹果自己的
     「照片图库 / 拍照 / 选取文件」三层菜单，网页代码关不掉。
     App 外壳里如果注册了 chrisPick（原生直接用系统相册选择器 PHPicker），
     这里就优先走原生：点一下直接进相册，不多一层。 */
  var pickWaiters = {};
  var pickSeq = 0;
  function nativePicker() {
    try { return (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.chrisPick) || null; }
    catch (e) { return null; }
  }
  /** 返回 Promise<File[]>；App 里没有原生选择器就返回 null（调用方退回 input） */
  function nativePick(limit) {
    var h = nativePicker();
    if (!h) return null;
    var key = 'p' + (++pickSeq);
    return new Promise(function (resolve) {
      pickWaiters[key] = resolve;
      try { h.postMessage({ key: key, limit: limit || 0 }); }
      catch (e) { delete pickWaiters[key]; resolve([]); }
      setTimeout(function () {                                  // 兜底：3 分钟没回来就当取消（挑图慢也不会丢）
        if (pickWaiters[key]) { delete pickWaiters[key]; resolve([]); }
      }, 180000);
    });
  }
  window.__chrisNativePick = function (key, items) {
    var done = pickWaiters[key];
    if (!done) return;
    delete pickWaiters[key];
    done((items || []).map(function (it) {
      return dataUrlToFile(it && it.dataUrl, (it && it.name) || 'photo.jpg');
    }).filter(Boolean));
  };
  function dataUrlToFile(dataUrl, name) {
    try {
      var m = /^data:([^;,]+);base64,(.*)$/.exec(String(dataUrl || ''));
      if (!m) return null;
      var bin = atob(m[2]);
      var buf = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
      return new File([buf], name, { type: m[1] });
    } catch (e) { return null; }
  }
  /** 点「相册」时统一走这里：App 里直接进相册，网页版退回原来的 input */
  function pickImages(inputId, limit, onFiles) {
    var p = nativePick(limit);
    if (p) {
      p.then(function (files) { if (files && files.length) onFiles(files); });
      return;
    }
    var el = $(inputId);
    if (!el) return;
    /* 关键：这个 input 可能刚被「拍摄」用过，身上还挂着 capture（capture 会让苹果直接开相机）。
       走相册这条路必须把 capture 摘掉，否则点「照片」会跑进拍照。 */
    el.removeAttribute('capture');
    el.accept = 'image/jpeg,image/png,image/heic,image/heif,image/webp,image/gif,image/tiff,image/bmp';
    el.__onFiles = onFiles;
    el.value = '';
    el.click();
  }

  function toast(msg) {
    var el = $('toast');
    el.textContent = msg; el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.hidden = true; }, 2200);
  }

  function sheet(items) {
    var box = $('sheetBox');
    box.innerHTML = items.map(function (it, i) {
      return '<button type="button" data-i="' + i + '">' + esc(it.label) + '</button>';
    }).join('') + '<button type="button" data-i="-1">取消</button>';
    $('sheet').hidden = false;
    box.onclick = function (e) {
      var b = e.target.closest('button'); if (!b) return;
      var i = Number(b.getAttribute('data-i'));
      $('sheet').hidden = true;
      if (i >= 0 && items[i] && items[i].run) items[i].run();
    };
    $('sheet').onclick = function (e) { if (e.target === $('sheet')) $('sheet').hidden = true; };
  }

  /* ---------------------------------------------------------- 时间显示 */
  /** 12 小时制 + 时段：凌晨 0–5 点 / 上午 6–11 点 / 下午 12–23 点 */
  function ampmTime(d) {
    var h = d.getHours();
    var ap = h < 6 ? '凌晨' : (h < 12 ? '上午' : '下午');
    var h12 = h % 12; if (h12 === 0) h12 = 12;
    var m = d.getMinutes();
    return ap + ' ' + h12 + ':' + (m < 10 ? '0' : '') + m;
  }

  function chatTime(iso) {
    var d = new Date(iso); if (isNaN(d.getTime())) return '';
    var now = new Date();
    var p2 = function (n) { return (n < 10 ? '0' : '') + n; };
    var day0 = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    var that = new Date(d.getFullYear(), d.getMonth(), d.getDate());
    var diff = Math.round((day0 - that) / 86400000);
    if (diff === 0) return ampmTime(d);          // 今天：上午 9:05 / 下午 3:24
    if (diff === 1) return '昨天';
    // 2～7 天：只显示星期几，不带时间
    if (diff > 1 && diff <= 7) return ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'][d.getDay()];
    // 超过 7 天：只显示 8月30日 这种（跨年才带上年份）
    if (d.getFullYear() === now.getFullYear()) return (d.getMonth() + 1) + '月' + d.getDate() + '日';
    return d.getFullYear() + '年' + (d.getMonth() + 1) + '月' + d.getDate() + '日';
  }
  function fullTime(iso) {
    var d = new Date(iso); if (isNaN(d.getTime())) return '';
    var now = new Date();
    var hm = ampmTime(d);
    if (d.toDateString() === now.toDateString()) return hm;
    var y = new Date(now.getTime() - 86400000);
    if (d.toDateString() === y.toDateString()) return '昨天 ' + hm;
    return (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + hm;
  }

  /** 朋友圈那种「刚刚 / 12分钟前 / 3小时前 / 昨天 下午 2:30 / 8月30日 下午 2:30」 */
  function momentTime(iso) {
    var d = new Date(iso); if (isNaN(d.getTime())) return '';
    var diff = Date.now() - d.getTime();
    if (diff < 60000) return '刚刚';
    if (diff < 3600000) return Math.floor(diff / 60000) + '分钟前';
    if (diff < 86400000) return Math.floor(diff / 3600000) + '小时前';
    return fullTime(iso);
  }

  /** 聊天里的时间分隔：今天只写时段+时间，昨天带「昨天」，更早带星期几（和参考图一致） */
  function dividerTime(iso) {
    var d = new Date(iso); if (isNaN(d.getTime())) return '';
    var now = new Date();
    var hm = ampmTime(d);
    if (d.toDateString() === now.toDateString()) return hm;
    var y = new Date(now.getTime() - 86400000);
    if (d.toDateString() === y.toDateString()) return '昨天 ' + hm;
    if (d.getFullYear() === now.getFullYear()) {
      return ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'][d.getDay()] + ' ' + hm;
    }
    return d.getFullYear() + '年' + (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + hm;
  }

  /* ---------------------------------------------------------- 登录 */
  function doLogin() {
    var err = $('lgErr');
    // 用账号密码面板时走密码登录，否则走手机号 + 验证码
    var byPass = !$('lgPassPanel').hidden;
    err.hidden = true;
    $('lgBtn').disabled = true;
    var job;
    if (byPass) {
      var u = $('lgUser').value.trim(), p = $('lgPass').value;
      if (!u || !p) {
        err.textContent = '请输入账号和密码'; err.hidden = false; $('lgBtn').disabled = false; return;
      }
      job = api('/login', { method: 'POST', body: JSON.stringify({ username: u, password: p }) });
    } else {
      var phone = ($('lgPhone').value || '').replace(/\D/g, '');
      var code = ($('lgCode').value || '').replace(/\D/g, '');
      if (!/^1[3-9]\d{9}$/.test(phone)) {
        err.textContent = '请填写 11 位手机号'; err.hidden = false; $('lgBtn').disabled = false; return;
      }
      if (code.length !== 6) {
        err.textContent = '请先获取并填写 6 位验证码'; err.hidden = false; $('lgBtn').disabled = false; return;
      }
      job = api('/login/phone', { method: 'POST', body: JSON.stringify({ phone: phone, code: code }) });
    }
    job.then(function () {
      // 刚登录进来，一定要落在「微信」第一页，不要续上上次待的页
      try { localStorage.removeItem('wx-tab'); } catch (e) { }
      var t0 = Date.now();
      showBootSplash();                    // 登录过场：彩色球转 2 秒
      return boot().then(function () { switchTab('chats'); }).then(function () {
        var left = Math.max(0, 2000 - (Date.now() - t0));
        return new Promise(function (res) { setTimeout(res, left); });
      }).then(function () { hideBootSplash(); });
    })
      .catch(function (e) { err.textContent = e.message; err.hidden = false; })
      .then(function () { $('lgBtn').disabled = false; });
  }

  /* 登录过场：满屏那颗彩色球 */
  function showBootSplash() {
    var el = $('bootSplash');
    if (!el) return;
    el.hidden = false;
    el.classList.remove('is-out');
  }
  function hideBootSplash() {
    var el = $('bootSplash');
    if (!el) return;
    el.classList.add('is-out');
    setTimeout(function () { el.hidden = true; el.classList.remove('is-out'); }, 280);
  }

  /* 获取验证码（本地没接短信，服务端会把码直接给出来，前台提示一下并自动填上） */
  function sendPhoneCode() {
    var err = $('lgErr');
    var phone = ($('lgPhone').value || '').replace(/\D/g, '');
    if (!/^1[3-9]\d{9}$/.test(phone)) {
      err.textContent = '请先填写 11 位手机号'; err.hidden = false; return;
    }
    err.hidden = true;
    var btn = $('lgCodeBtn');
    btn.disabled = true;
    btn.textContent = '发送中…';
    api('/login/phone-code', { method: 'POST', body: JSON.stringify({ phone: phone }) })
      .then(function (d) {
        if (d && d.devCode) {
          $('lgCode').value = d.devCode;
          toast('验证码：' + d.devCode + '（已自动填上，5 分钟内有效）');
        } else {
          toast('验证码已发送');
        }
        var left = 60;
        var t = setInterval(function () {
          left -= 1;
          if (left <= 0) {
            clearInterval(t);
            btn.disabled = false;
            btn.classList.remove('is-off');
            btn.textContent = '获取验证码';
          } else {
            btn.classList.add('is-off');
            btn.textContent = left + ' 秒后重发';
          }
        }, 1000);
      })
      .catch(function (e) {
        btn.disabled = false;
        btn.textContent = '获取验证码';
        err.textContent = e.message; err.hidden = false;
      });
  }

  function setCountry(name, cc) {
    $('lgCountryVal').textContent = name + ' (' + cc + ')';
    $('lgCc').textContent = cc;
  }

  function doLogout() {
    api('/logout', { method: 'POST' }).catch(function () { }).then(function () { location.reload(); });
  }

  /* ---------------------------------------------------------- 引导 */
  /* 扫码进群：在登录页之前存下来的邀请码，登录完成后自动接着进群 */
  function pendingJoin() {
    var code = '';
    try { code = localStorage.getItem('chris.pendingJoin') || ''; } catch (e) { }
    if (!code) return;
    try { localStorage.removeItem('chris.pendingJoin'); } catch (e) { }
    api('/join', { method: 'POST', body: JSON.stringify({ code: code }) }).then(function (d) {
      toast(d && d.already ? '你已经在群里了' : ('已加入「' + ((d && d.chat && d.chat.title) || '群聊') + '」'), 'ok');
      loadChats();
    }).catch(function (e) { toast(e.message || '进群失败'); });
  }

  /* 扫别人二维码加好友：登录页之前存下来的那个码，登录完成后自动发申请 */
  function pendingAdd() {
    var code = '';
    try { code = localStorage.getItem('chris.pendingAdd') || ''; } catch (e) { }
    if (!code) return;
    try { localStorage.removeItem('chris.pendingAdd'); } catch (e) { }
    api('/add-by-code', { method: 'POST', body: JSON.stringify({ code: code }) }).then(function (d) {
      toast(d && d.accepted ? '你们已经是好友了' : '好友申请已发给 ' + ((d && d.user && d.user.nickname) || '对方'), 'ok');
      loadChats();
      loadContacts();
    }).catch(function (e) { toast(e.message || '加好友失败'); });
  }

  function boot() {
    return api('/me').then(function (d) {
      S.me = d.user;
      $('loginScreen').hidden = true;
      $('app').hidden = false;
      fillMe();
      loadMsgCache();          // 先把上次同步下来的聊天记录铺上，打开就有
      connect();
      loadPlusPanel();
      loadGifts();
      loadStickers();
      loadStatuses();
      loadPayPwdState();      // 有没有设置支付密码（安全中心里设置）
      // 回到上次待着的那一页（刷新页面 / 下拉刷新都不会跳回主页）
      var lastTab = '';
      try { lastTab = localStorage.getItem('wx-tab') || ''; } catch (e) { }
      if (lastTab && lastTab !== S.tab) switchTab(lastTab);
      /* 先补齐「AI 助手 / 贾维斯AI / 腾讯新闻」再拉列表：刚注册、刚退出重登也一样在 */
      return api('/bots/ensure', { method: 'POST' }).catch(function () { })
    .then(function () { applyUiCss(); return Promise.all([loadChats(), loadContacts(), loadDiscover(), loadMePage()]); });
    }).catch(function () {
      $('loginScreen').hidden = false;
      $('app').hidden = true;
    });
  }

  /* ---------------------------------------------------------- 品牌字体（后台「字体字号」里上传的）
     后台传了字体文件，手机端也一起用：注入 @font-face 并把 --font-ios 换成它，
     这样想全站统一成某个字体（比如苹方）不用改代码，后台传一次就行。 */
  function applyBrandFont(branding) {
    if (!branding || !branding.fontUrl) return;
    var url = String(branding.fontUrl);
    var fam = String(branding.fontFamily || branding.fontName || 'wx-brand').trim();
    var id = 'wx-brand-font';
    var old = document.getElementById(id);
    if (old) old.parentNode.removeChild(old);
    var st = document.createElement('style');
    st.id = id;
    st.textContent = '@font-face{font-family:"' + fam.replace(/"/g, '') + '";src:url("' + url + '");font-display:swap;}' +
      ':root{--font-ios:"' + fam.replace(/"/g, '') + '",-apple-system,BlinkMacSystemFont,system-ui,"PingFang SC",sans-serif;}' +
      'body,button,input,textarea,select{font-family:var(--font-ios);}';
    document.head.appendChild(st);
  }
  function loadBrandFont() {
    api('/branding').then(function (d) {
      S.branding = (d && d.branding) || {};          /* 品牌设置里可能有默认聊天背景 */
      applyBrandFont(S.branding);
      applyMobileChatBg();
    }).catch(function () { });
  }

  /* ---------------------------------------------------------- 版本自动刷新
     服务器端每次改前端文件，版本号都会变；这里定时比对，变了就自动刷新，
     省得手机上一直看到旧的缓存页面（在打字/开着弹层的时候先提示，不乱刷）。 */
  var loadedVersion = '';
  function checkVersion() {
    fetch('/api/version', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (d) {
      var v = d && d.version;
      if (!v) return;
      if (!loadedVersion) { loadedVersion = v; return; }
      if (v === loadedVersion) return;
      var typing = false;
      try {
        var inp = $('msgInput');
        typing = !!(inp && inp.value && document.activeElement === inp);
      } catch (e) { typing = false; }
      var sheetOpen = !$('sheet').hidden || !$('payMask').hidden || !$('ntMask').hidden;
      if (typing || sheetOpen) {
        if ($('verBar')) $('verBar').hidden = false;
        return;
      }
      location.reload();
    }).catch(function () { });
  }
  function bindVersionCheck() {
    var bar = $('verBar');
    if (bar) bar.addEventListener('click', function () { location.reload(); });
    checkVersion();
    /* 20 秒一次太勤了：每 20 秒一次 no-store 的网络请求，正好卡在操作中间就顿一下。
       改成 60 秒（版本更新提示晚一分钟无所谓），滑动中不查。 */
    setInterval(function () {
      if (document.documentElement.classList.contains('is-scrolling')) return;
      checkVersion();
    }, 60000);
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) checkVersion();
    });
  }

  /* 朋友圈红点的三重兜底：
     ① 每 45 秒轻量刷一次（只取 1 条朋友圈，请求很小）；
     ② App 回到前台刷一次；③ 点开「发现」刷一次（见 switchTab）。
     长连接偶尔断线时会漏掉推送，有这三层就不会「有人发了朋友圈但没红点」。 */
  function bindMomentsBadgeWatch() {
    setInterval(function () {
      if (document.hidden) return;
      if (document.documentElement.classList.contains('is-scrolling')) return;
      loadMomentsBadge();
    }, 45000);
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) { loadMomentsBadge(); refreshDotCounts(); }
    });
  }

  /* 通讯录红点的兜底：推送偶尔会漏（手机在后台、长连接正在重连），
     每 25 秒 + 每次回到前台都轻量问一次服务器「有几条好友申请」。 */
  function refreshDotCounts() {
    if (!S.me) return;
    api('/badge-counts').then(function (d) {
      if (!d) return;
      if (d.friendRequests != null) {
        var have = (S.incoming || []).length;
        setTabBadge('tabBadgeContacts', d.friendRequests);
        /* 和本地列表对不上（漏了推送）→ 重新拉一次通讯录，行内那个小数字也会跟着重画 */
        if (have !== d.friendRequests) loadContacts();
      }
      if (d.momentUnread != null) setTabBadge('tabBadgeMoments', d.momentUnread, true);
    }).catch(function () { });
  }
  setInterval(function () { if (!document.hidden && S.me) refreshDotCounts(); }, 25000);

  function fillMe() {
    var name = S.me.nickname || S.me.username;
    var face = S.me.avatar ? '<img src="' + esc(S.me.avatar) + '" alt="" loading="lazy" decoding="async">' : esc(initials(name));
    $('meAvatar').innerHTML = face;
    $('coverAvatar').innerHTML = face;
    $('meName').textContent = name;
    $('coverName').textContent = name;
    $('meId').textContent = '微信号：' + S.me.username;
    renderProfile();
    paintStatusChip();
    applyStatusTheme();
    applyMobileChatBg();
  }

  /* ---------------------------------------------------------- 聊天背景（手机端也能换）
     和电脑版共用同一个字段：users.chatBackground。留空 / auto 就是默认底色。 */
  function applyMobileChatBg() {
    var box = $('messages');
    if (!box) return;
    var page = $('chatScreen');                 // 整页都铺背景图：顶部导航那一块也跟着变
    var bg = (S.me && S.me.chatBackground) || (S.branding && S.branding.chatBackground) || '';
    if (bg && bg !== 'auto') {
      /* 深色模式里有一条 `background: transparent !important` 会把这个内联背景图盖掉，
         所以额外挂个类 + 一个 CSS 变量，让样式表里那条带 !important 的规则放行（见 m.css）。 */
      [box, page].forEach(function (el) {
        if (!el) return;
        el.classList.add('has-chatbg');
        el.style.setProperty('--chat-bg', 'url("' + bg + '")');
        el.style.backgroundImage = 'url("' + bg + '")';
        el.style.backgroundSize = 'cover';
        el.style.backgroundPosition = 'center';
        el.style.backgroundRepeat = 'no-repeat';
      });
    } else {
      [box, page].forEach(function (el) {
        if (!el) return;
        el.classList.remove('has-chatbg');
        el.style.removeProperty('--chat-bg');
        el.style.backgroundImage = '';
        el.style.backgroundSize = '';
        el.style.backgroundPosition = '';
        el.style.backgroundRepeat = '';
      });
    }
  }

  function saveChatBg(url) {
    api('/me', { method: 'PATCH', body: JSON.stringify({ chatBackground: url || '' }) })
      .then(function (d) {
        if (d && d.user) S.me = d.user;
        applyMobileChatBg();
        toast(url ? '聊天背景已更新' : '已恢复默认背景');
      })
      .catch(function (e) { toast(e.message || '设置失败'); });
  }

  function openChatBgSheet() {
    /* 直接进相册（少一层菜单）；已经设过背景的，再多给一个「恢复默认」 */
    var has = !!((S.me && S.me.chatBackground) || (S.branding && S.branding.chatBackground));
    var rows = [];
    if (has) rows.push({ label: '恢复默认背景', run: function () { saveChatBg(''); } });
    if (rows.length) sheet(rows);
    var el = $('chatBgFile');
    if (el) setTimeout(function () {
      pickImages('chatBgFile', 1, function (files) { saveChatBgFile(files[0]); });
    }, has ? 260 : 60);
  }

  /* 换聊天背景：选图 → 上传 → 存到自己资料 */
  function saveChatBgFile(file) {
    if (!file) return;
    if (file.size > 12 * 1024 * 1024) { toast('图片不能超过 12MB'); return; }
    var reader = new FileReader();
    reader.onload = function () {
      toast('正在上传聊天背景…');
      api('/upload', { method: 'POST', body: JSON.stringify({ dataUrl: String(reader.result), filename: file.name }) })
        .then(function (d) { saveChatBg(d.url); })
        .catch(function (err) { toast(err.message || '上传失败'); });
    };
    reader.readAsDataURL(file);
  }

  /* ---------------------------------------------------------- 个人信息（手机端改资料） */
  function openProfile() {
    renderProfile();
    $('profileScreen').hidden = false;
  }

  function closeProfile() { $('profileScreen').hidden = true; }

  /* ---------------------------------------------------------- 名片（点任何人头像都走这里）
     聊天里的头像、通讯录的头像、朋友圈的头像，点一下就是微信那张「详细资料」页：
     头像 + 名字 + 微信号 + 地区，下面「发消息 / 语音通话 / 视频通话」。 */
  var cardUserId = null;
  function openCard(id) {
    if (!id) return;
    if (S.me && id === S.me.id) { openProfile(); return; }      // 点自己头像 → 我的个人信息
    cardUserId = id;
    $('cdAvatar').innerHTML = '';
    $('cdName').textContent = '正在打开…';
    $('cdGender').innerHTML = '';
    $('cdNick').textContent = '昵称：—';
    $('cdWx').textContent = '微信号：—';
    $('cdRegion').textContent = '地区：—';
    $('cdPhoneRow').hidden = true;
    $('cdThumbs').innerHTML = '';
    $('cdThumbCard').hidden = true;
    $('cdActs').innerHTML = '';
    $('cardScreen').hidden = false;
    var box = $('cardScroll'); if (box) box.scrollTop = 0;
    api('/users/' + encodeURIComponent(id)).then(function (d) {
      if (cardUserId !== id) return;
      renderCard(d.user || {});
    }).catch(function (e) {
      toast(e.message || '打不开名片');
      closeCard();
    });
  }
  function closeCard() { cardUserId = null; $('cardScreen').hidden = true; }

  function chatWith(id) {
    return api('/chats/direct', { method: 'POST', body: JSON.stringify({ userId: id }) }).then(function (d) {
      var chat = d.chat;
      if (!S.chats.some(function (c) { return c.id === chat.id; })) S.chats.unshift(chat);
      renderChats();
      openChat(chat.id);
      return chat;
    });
  }

  /* 性别图标：微信是蓝色（#10AEFF）的小图标 */
  var CD_G_MALE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="9.6" cy="14.4" r="5.6"/><path d="M13.6 10.4 20 4"/><path d="M15 4h5v5"/></svg>';
  var CD_G_FEMALE = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8.8" r="5.6"/><path d="M12 14.4V21"/><path d="M9 18.4h6"/></svg>';
  /* 底部两个按钮的图标：直接从参考图上抠下来的（发消息 = 气泡，音视频通话 = 摄像机） */
  var CD_IC_CHAT = '<img class="cd-ic-img is-chat" src="cd-ic-chat.png" alt="">';
  var CD_IC_VIDEO = '<img class="cd-ic-img is-video" src="cd-ic-video.png" alt="">';

  function renderCard(u) {
    $('cardNavTitle').textContent = '';
    $('cdAvatar').innerHTML = u.avatar ? '<img src="' + esc(u.avatar) + '" alt="">' : esc(initials(u.nickname || u.username));
    $('cdName').textContent = u.nickname || u.username || '—';
    $('cdGender').innerHTML = u.gender === 'female' ? CD_G_FEMALE : (u.gender === 'male' ? CD_G_MALE : '');
    $('cdNick').textContent = '昵称：' + (u.nickname || u.username || '—');
    $('cdWx').textContent = '微信号：' + (u.username || '—');
    $('cdRegion').textContent = '地区：' + (u.region || '未知');
    /* 电话那一行：微信有号码才显示 */
    var phone = u.phone || '';
    $('cdPhoneRow').hidden = !phone;
    $('cdPhone').textContent = phone || '—';
    /* 朋友圈那一行：他发过朋友圈才显示（最多放 5 张小图），没发过整行不出现 */
    api('/moments?limit=6&userId=' + encodeURIComponent(u.id)).then(function (d) {
      if (cardUserId !== u.id) return;
      var list = d.moments || [];
      var imgs = [];
      list.forEach(function (m) {
        (m.images || []).forEach(function (src) { if (imgs.length < 5) imgs.push(src); });
      });
      $('cdThumbs').innerHTML = imgs.map(function (src) {
        return '<div class="cd-thumb"><img src="' + esc(src) + '" alt="" loading="lazy" decoding="async"></div>';
      }).join('');
      $('cdThumbCard').hidden = !list.length;
    }).catch(function () { $('cdThumbCard').hidden = true; });
    /* 底部按钮：好友就是参考图那两行「发消息 / 音视频通话」 */
    var acts = '';
    if (u.relation === 'friend' || u.relation === 'self') {
      acts = '<button class="cd-act" data-cd="msg">' + CD_IC_CHAT + '发消息</button>' +
        '<button class="cd-act" data-cd="call">' + CD_IC_VIDEO + '音视频通话</button>';
    } else if (u.relation === 'incoming') {
      acts = '<button class="cd-act" data-cd="agree">同意好友申请</button>' +
        '<button class="cd-act" data-cd="msg">' + CD_IC_CHAT + '发消息</button>';
    } else if (u.relation === 'requested') {
      acts = '<button class="cd-act" data-cd="pending">已发送好友申请</button>';
    } else {
      acts = '<button class="cd-act" data-cd="add">添加到通讯录</button>';
    }
    $('cdActs').innerHTML = acts;
    $('cdActs').onclick = function (e) {
      var b = e.target.closest('[data-cd]'); if (!b) return;
      var act = b.getAttribute('data-cd');
      if (act === 'msg') { closeCard(); chatWith(u.id).catch(function (err) { toast(err.message); }); return; }
      if (act === 'call') {
        closeCard();
        chatWith(u.id).then(function () { setTimeout(function () { startCall('video'); }, 260); })
          .catch(function (err) { toast(err.message); });
        return;
      }
      if (act === 'add') {
        api('/friends/request', { method: 'POST', body: JSON.stringify({ username: u.username }) })
          .then(function () { toast('好友申请已发出'); openCard(u.id); loadContacts(); })
          .catch(function (err) { toast(err.message || '加好友失败'); });
        return;
      }
      if (act === 'agree') {
        var req = (S.incoming || []).filter(function (r) { return r.id === u.id || r.userId === u.id; })[0];
        closeCard();
        if (req && req.requestId) respondRequest(req.requestId, true);
        else toast('到「通讯录 → 新的朋友」里同意');
        return;
      }
      if (act === 'pending') { toast('已经发过申请了，等对方通过'); }
    };
  }

  function renderProfile() {
    if (!$('pfNameVal') || !S.me) return;
    var me = S.me;
    $('pfNameVal').textContent = me.nickname || me.username || '';
    $('pfUserVal').textContent = me.username || '';
    $('pfGenderVal').textContent = me.gender === 'male' ? '男' : (me.gender === 'female' ? '女' : '未设置');
    $('pfRegionVal').textContent = me.region || '未设置';
    var phone = String(me.phone || '');
    $('pfPhoneVal').textContent = phone
      ? (phone.length >= 7 ? phone.slice(0, 3) + '******' + phone.slice(-2) : phone)
      : '未绑定';
    var pfHint = document.querySelector('.pf-hint');
    if (pfHint) {
      var chk = canChangePhone();
      pfHint.textContent = chk.ok
        ? '改完自动保存；手机号一年只能改一次，好友那边在线就能看到新头像和名字。'
        : ('改完自动保存；' + chk.msg);
    }
    $('pfPatVal').textContent = localOf('wx-pat', '朋友拍了拍你');
    $('pfBioVal').textContent = me.bio || '未填写';
    $('pfRingVal').textContent = localOf('wx-ring', '本机默认');
    $('pfAvatar').innerHTML = me.avatar
      ? '<img src="' + esc(me.avatar) + '" alt="" decoding="async">'
      : '<span>' + esc(initials(me.nickname || me.username)) + '</span>';
  }

  /* 一些只存在本机的设置（拍一拍 / 来电铃声），按账号分开存 */
  function localKey(prefix) { return prefix + ':' + ((S.me && S.me.username) || 'me'); }
  function localOf(prefix, fallback) {
    try { return localStorage.getItem(localKey(prefix)) || fallback; } catch (e) { return fallback; }
  }
  function setLocal(prefix, value) {
    try { localStorage.setItem(localKey(prefix), value); } catch (e) { }
  }

  /* 手机号一年只能改一次：算下次可改的日期 */
  /* ---------------------------------------------------------- 转账页（照着参考图） */
  var tfAmount = '0', tfNote = '', tfPeer = '';

  function openTransfer() {
    if (!S.activeChat) { toast('先打开一个聊天，再转账'); return; }
    var chat = S.chats.filter(function (c) { return c.id === S.activeChat; })[0] || {};
    var title = chat.title || '好友';
    var friend = (S.friends || []).filter(function (f) { return f.nickname === title || f.id === title; })[0] || null;
    tfPeer = (friend && friend.username) || chat.peerUsername || '';
    tfAmount = '';                     // 一开始不显示 0.00，空着等输入
    tfNote = '';
    // 实名（后台填的）脱敏后跟在名字后面：转账给 赵伟（*伟）；没填实名就不显示括号
    var mask = (friend && friend.realName) || '';
    $('tfTitle').textContent = '转账给 ' + title + (mask ? '（' + mask + '）' : '');
    $('tfPeer').textContent = '微信号：' + (tfPeer || '—');
    $('tfPeer').hidden = !tfPeer;
    // 收款人的头像（和「转账给 XX」同一行，靠右）
    var face = (chat.avatar || (friend && friend.avatar) || '');
    $('tfAvatar').innerHTML = face
      ? '<img src="' + esc(face) + '" alt="" decoding="async">'
      : esc((title || '?').trim().slice(0, 1));
    $('tfNoteRow').textContent = '添加转账说明';
    $('tfNoteRow').classList.remove('is-set');
    paintTransferAmount();
    $('transferScreen').hidden = false;
    /* 和微信一样：一进转账页，数字键盘就弹出来、金额处是输入状态（以前要先点一下金额才出来，
       看着像「下面没渲染出来」） */
    $('tfPad').classList.add('is-on');
    $('tfAmountLine').classList.add('is-focus');
  }

  function paintTransferAmount() {
    // 数字按位铺开；单位在下划线下面、对齐第一个数字，从「千」到「百万」
    var UNIT = { 4: '千', 5: '万', 6: '十万', 7: '百万' };
    var chars = String(tfAmount || '').split('');
    var intLen = String(tfAmount || '').split('.')[0].length;
    var unitText = intLen ? (UNIT[intLen] || (intLen < 4 ? '千' : '百万')) : '';
    var digitsHtml = '', unitsHtml = '', di = 0;
    chars.forEach(function (ch) {
      if (ch === '.') {
        digitsHtml += '<span class="cell">.</span>';
        unitsHtml += '<span class="cell"></span>';
        return;
      }
      digitsHtml += '<span class="cell">' + esc(ch) + '</span>';
      unitsHtml += '<span class="cell">' + (di === 0 ? unitText : '') + '</span>';
      di += 1;
    });
    $('tfDigits').innerHTML = digitsHtml || '<span class="cell"></span>';
    $('tfUnits').innerHTML = unitsHtml;
    var value = Number(tfAmount) || 0;
    $('tfSend').disabled = !(value > 0);
  }

  /* 键盘：数字、小数点、删除 */
  function tfPress(k) {
    if (k === 'del') {
      tfAmount = tfAmount.length > 1 ? tfAmount.slice(0, -1) : '';
      paintTransferAmount();
      return;
    }
    if (k === '.') {
      if (tfAmount.indexOf('.') >= 0) return;
      tfAmount = (tfAmount || '0') + '.';
      paintTransferAmount();
      return;
    }
    if (tfAmount.indexOf('.') >= 0 && tfAmount.split('.')[1].length >= 2) return;   // 最多两位小数
    if (tfAmount === '' || tfAmount === '0') tfAmount = k; else tfAmount += k;
    if (tfAmount.length > 10) tfAmount = tfAmount.slice(0, 10);
    paintTransferAmount();
  }

  function sendTransfer() {
    // 点「转账」不马上转：先出 2 秒彩球加载，再到确认面板（面板里确认才真的转）
    var value = Number(tfAmount) || 0;
    if (!(value > 0)) { toast('请先输入转账金额'); return; }
    if (!S.activeChat) { toast('会话不见了，重新打开聊天再试'); return; }
    payValue = value;
    $('payLoad').hidden = false;
    clearTimeout(payTimer);
    payTimer = setTimeout(function () {
      $('payLoad').hidden = true;
      openPaySheet();
    }, 2000);
  }

  /* 确认支付面板：照着参考图排的，按住顶部往下滑可以关掉 */
  var payValue = 0, payTimer = null;
  var payDrag = { y0: 0, dy: 0, on: false };

  function openPaySheet() {
    var chat = S.chats.filter(function (c) { return c.id === S.activeChat; })[0] || {};
    var title = chat.title || '好友';
    var friend = (S.friends || []).filter(function (f) { return f.nickname === title || f.id === title; })[0] || null;
    var mask = (friend && friend.realName) || '';                 // 后台填的实名，脱敏后的
    $('payTo').textContent = payMode === 'redpacket'
      ? ('发红包到「' + (title || '群聊') + '」')
      : ('向 ' + title + (mask ? '（' + mask + '）' : '') + '转账');
    $('paySum').textContent = '¥' + (Number(payValue) || 0).toFixed(2);
    payPwd = '';
    paintPayPwd();
    paintPayPwdTip();
    loadPayPwdState();                                            // 顺带刷新「有没有设置支付密码」
    loadBalance();                                                // 顺带刷新零钱余额
    paintPayMethod();
    var sheet = $('paySheet');
    sheet.classList.remove('is-drag');
    sheet.style.transform = '';
    $('payMask').hidden = false;
  }

  function closePaySheet() {
    var sheet = $('paySheet');
    sheet.classList.remove('is-drag');
    sheet.style.transform = '';
    $('payMask').hidden = true;
  }

  function cancelTransfer() {
    clearTimeout(payTimer);
    $('payLoad').hidden = true;
    closePaySheet();
    payValue = 0;
  }

  // 付款走服务端：余额不够会直接失败，够了就真扣（对方余额实时加）
  function payConfirm(opts) {
    var value = Number(payValue) || 0;
    if (!(value > 0)) { closePaySheet(); return; }
    var o = opts || {};
    if (payMode === 'redpacket') {
      /* 发红包：和转账共用一个支付面板，只是接口和参数不一样 */
      api('/pay/redpacket', {
        method: 'POST',
        body: JSON.stringify({
          chatId: S.activeChat,
          amount: value,
          count: rpDraft.count,
          type: rpDraft.lucky ? 'lucky' : 'normal',
          note: rpDraft.note,
          password: o.password || '',
          face: !!o.face
        })
      }).then(function (d) {
        if (S.me) S.me.balance = Number(d.balance) || 0;
        paintPayMethod();
        closePaySheet();
        payMode = 'transfer';
        loadChats();
        renderMessages();
        toast('红包已发出');
      }).catch(function (e) {
        payPwd = ''; paintPayPwd();
        if (e.status !== 402) payPwdShake();
        paintPayPwdTip();
        toast(e.message || '发红包失败');
      });
      return;
    }
    api('/pay/transfer', {
      method: 'POST',
      body: JSON.stringify({
        chatId: S.activeChat,
        amount: value,
        note: tfNote || '',
        method: payMethod,
        password: o.password || '',
        face: !!o.face
      })
    }).then(function (d) {
      if (S.me) S.me.balance = Number(d.balance) || 0;
      paintPayMethod();
      closePaySheet();
      showPaySuccess(d, value);                 // 支付成功单独一页
      $('transferScreen').hidden = true;
      setTimeout(function () { setPlusOpen(false); }, 80);
      payValue = 0;
    }).catch(function (e) {
      payPwd = ''; paintPayPwd();
      if (e.status !== 402) payPwdShake();          // 余额不足就别抖了，提示去充值
      paintPayPwdTip();
      toast(e.message || '付款失败');
    });
  }

  /* 支付成功页：绿勾 + 支付成功 + 待 XX 确认收款 + 金额 + 明细 + 完成 */
  function showPaySuccess(d, amount) {
    var chat = S.chats.filter(function (c) { return c.id === S.activeChat; })[0] || {};
    var title = chat.title || '';
    var friend = (S.friends || []).filter(function (f) { return f.nickname === title || f.id === title; })[0] || null;
    var who = (friend && friend.nickname) || (chat.type === 'group' ? '' : title);
    $('okSub').textContent = who ? ('待' + who + '确认收款') : '转账已发出，待对方确认收款';
    $('okSum').textContent = '¥' + (Number(amount) || 0).toFixed(2);
    $('okMethod').textContent = payMethod === 'card' ? PAY_CARD.name : '余额';
    $('okBalance').textContent = money(d && d.balance !== undefined ? d.balance : balanceOf());
    var note = (tfNote || '').trim();
    $('okNoteRow').hidden = !note;
    if (note) $('okNote').textContent = note;
    $('payOkScreen').hidden = false;
  }

  /* ---------------- 6 位支付密码（面板里输入，安全中心里设置） ---------------- */
  var payPwd = '', payHasPwd = false, ppStep = 'set1', ppTmp = '', ppOld = '';

  function paintPayPwd() {
    var cells = $('payPwd').children;
    for (var i = 0; i < cells.length; i++) cells[i].classList.toggle('is-on', i < payPwd.length);
  }
  function paintPayPwdTip() {
    var tip = $('payPwdTip');
    var short = (Number(payValue) || 0) > balanceOf();      // 哪个付款方式都是从余额扣
    if (short) {
      tip.textContent = '余额只剩 ' + money(balanceOf()) + '，点这里去充值';
      tip.classList.add('is-link');
      return;
    }
    tip.textContent = payHasPwd ? '请输入 6 位支付密码' : '还没有设置支付密码，点这里去安全中心设置';
    tip.classList.toggle('is-link', !payHasPwd);
  }
  function payPwdShake() {
    var box = $('payPwd');
    box.classList.remove('is-bad');
    void box.offsetWidth;
    box.classList.add('is-bad');
    setTimeout(function () { box.classList.remove('is-bad'); }, 420);
  }
  function payPwdKey(k) {
    if (!payHasPwd) { openSecurityCenter(true); return; }        // 没设置过：直接去做设置
    if (k === 'del') { payPwd = payPwd.slice(0, -1); paintPayPwd(); return; }
    if (payPwd.length >= 6) return;
    payPwd += k;
    paintPayPwd();
    if (payPwd.length === 6) payConfirm({ password: payPwd });     // 满 6 位就交给服务端校验
  }
  function loadPayPwdState() {
    return api('/me/paypassword').then(function (d) {
      payHasPwd = !!d.has;
      if (!payHasPwd) { payPwd = ''; paintPayPwd(); }
      paintPayPwdTip();
      if ($('secPayPwdVal')) $('secPayPwdVal').textContent = d.has ? '已设置' : '未设置';
      return d;
    }).catch(function () { });
  }

  /* ---------------- 付款方式：余额 / 建设银行储蓄卡 ---------------- */
  var PAY_CARD = { name: '建设银行储蓄卡', sub: '尾号 2125' };
  var payMethod = (function () {
    try { return localStorage.getItem('wx-pay-method') === 'card' ? 'card' : 'balance'; } catch (e) { return 'balance'; }
  })();

  function money(n) {
    var v = Number(n) || 0;
    var s = Math.abs(v).toFixed(2).split('.');
    s[0] = s[0].replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    return (v < 0 ? '-' : '') + '¥' + s.join('.');
  }
  function balanceOf() {
    if (!S.me) return 0;
    if (S.me.balance === undefined || S.me.balance === null) return 0;
    return Number(S.me.balance) || 0;
  }
  function loadBalance() {
    return api('/me').then(function (d) {
      if (d && d.user) { S.me = Object.assign({}, S.me, { balance: Number(d.user.balance) || 0 }); }
      paintPayMethod();
      if ($('payPwdTip')) paintPayPwdTip();
      return d;
    }).catch(function () { });
  }
  function payMethodSVG(kind) {
    if (kind === 'card') {
      return '<svg viewBox="0 0 24 24" fill="none"><path d="M12 2.5c5.1 0 9.3 3.3 9.3 7.3 0 2.4-1.5 4.5-3.8 5.8H6.5C4.2 14.3 2.7 12.2 2.7 9.8 2.7 5.8 6.9 2.5 12 2.5Z" fill="#124284"/><path d="M7.3 15.9h9.4v5.6H7.3z" fill="#124284"/><path d="M10.2 15.9h3.6v5.6h-3.6z" fill="#eaf3fc"/></svg>';
    }
    return '<svg viewBox="0 0 24 24" fill="none" stroke="#07c160" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="6.2" width="18" height="12.4" rx="2.6"/><path d="M3 10.4h18"/><circle cx="16.6" cy="14.6" r="1.2" fill="#07c160" stroke="none"/></svg>';
  }
  function paintPayMethod() {
    var isCard = payMethod === 'card';
    $('payMIcon').innerHTML = payMethodSVG(isCard ? 'card' : 'balance');
    $('payMName').textContent = isCard ? PAY_CARD.name : '余额';
    $('payMSub').textContent = isCard ? PAY_CARD.sub : money(balanceOf());
    if ($('pmList') && !$('pmMask').hidden) renderPayMethods();
  }

  /* 付款方式选择：半高面板，按住顶部往下拖可以关 */
  var pmDrag = { y0: 0, dy: 0, on: false };
  function renderPayMethods() {
    var rows = [
      { key: 'balance', name: '余额', sub: money(balanceOf()), icon: 'balance' },
      { key: 'card', name: PAY_CARD.name, sub: PAY_CARD.sub, icon: 'card' }
    ];
    $('pmList').innerHTML = rows.map(function (r) {
      return '<button class="pm-row' + (payMethod === r.key ? ' is-on' : '') + '" data-pm="' + r.key + '">' +
        '<span class="pm-ico">' + payMethodSVG(r.icon) + '</span>' +
        '<span class="pm-txt"><span class="pm-name">' + esc(r.name) + '</span><span class="pm-sub">' + esc(r.sub) + '</span></span>' +
        '<span class="pm-tick"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4.9 12.7l4.7 4.7 9.5-10.4"/></svg></span>' +
        '</button>';
    }).join('');
  }
  function openPayMethodSheet() {
    loadBalance().then(function () {
      renderPayMethods();
      var sheet = $('pmSheet');
      sheet.classList.remove('is-drag');
      sheet.style.transform = '';
      $('pmMask').hidden = false;
    });
  }
  function closePayMethodSheet() {
    var sheet = $('pmSheet');
    sheet.classList.remove('is-drag');
    sheet.style.transform = '';
    $('pmMask').hidden = true;
  }
  function pickPayMethod(key) {
    payMethod = key === 'card' ? 'card' : 'balance';
    try { localStorage.setItem('wx-pay-method', payMethod); } catch (e) { }
    paintPayMethod();
    paintPayPwdTip();
    closePayMethodSheet();
    toast('付款方式：' + (payMethod === 'card' ? PAY_CARD.name : '余额 ' + money(balanceOf())));
  }
  function rechargeBalance(amount) {
    api('/me/recharge', { method: 'POST', body: JSON.stringify({ amount: amount }) })
      .then(function (d) {
        if (S.me) S.me.balance = Number(d.balance) || 0;
        paintPayMethod();
        paintPayPwdTip();
        if ($('pmList') && !$('pmMask').hidden) renderPayMethods();
        toast('充值成功，余额 ' + money(d.balance));
      })
      .catch(function (e) { toast(e.message || '充值失败'); });
  }
  function openRechargeSheet() {
    closePayMethodSheet();                 // 先收起来，充值面板才不会被挡住
    sheet([
      { label: '充值 ¥100', run: function () { rechargeBalance(100); } },
      { label: '充值 ¥500', run: function () { rechargeBalance(500); } },
      { label: '充值 ¥1000', run: function () { rechargeBalance(1000); } },
      { label: '充值 ¥2000', run: function () { rechargeBalance(2000); } }
    ]);
  }

  /* 安全中心页 */
  function openSecurityCenter(fromPay) {
    $('secScreen').hidden = false;
    api('/me/security').then(function (d) {
      $('secScore').textContent = d.score + ' 分';
      $('secDevices').textContent = d.deviceCount + ' 台';
      payHasPwd = !!d.hasPayPassword;
      $('secPayPwdVal').textContent = payHasPwd ? '已设置' : '未设置';
      if (fromPay) paintPayPwdTip();
    }).catch(function (e) { toast(e.message || '读取失败'); });
  }

  /* 支付密码页：没设置过 → 输两遍；已设置 → 先验原密码，再输两遍 */
  function openPayPwdPage() {
    ppStep = payHasPwd ? 'old' : 'set1';
    ppTmp = ''; ppOld = ''; payPwd = '';
    paintPp();
    $('ppScreen').hidden = false;
  }
  function ppTitleOf(step) {
    return { old: '输入原支付密码', set1: '设置支付密码', set2: '再输一次支付密码', new1: '输入新支付密码', new2: '再输一次新密码' }[step] || '支付密码';
  }
  function ppTipOf(step) {
    return { old: '请先输入当前的 6 位支付密码', set1: '请输入 6 位数字支付密码', set2: '请再次输入，两次要一样', new1: '请输入新的 6 位支付密码', new2: '请再次输入新的支付密码' }[step] || '';
  }
  function paintPp() {
    $('ppTitle').textContent = ppTitleOf(ppStep);
    $('ppTip').textContent = ppTipOf(ppStep);
    var cells = $('ppCells').children;
    for (var i = 0; i < cells.length; i++) cells[i].classList.toggle('is-on', i < payPwd.length);
  }
  function ppHint(text, ok) {
    $('ppHint').textContent = text || '';
    $('ppHint').style.color = ok ? '#07c160' : '#e5484d';
  }
  function ppShake() {
    var box = $('ppCells');
    box.classList.remove('is-bad');
    void box.offsetWidth;
    box.classList.add('is-bad');
    setTimeout(function () { box.classList.remove('is-bad'); }, 420);
  }
  function ppKey(k) {
    if (k === 'del') { payPwd = payPwd.slice(0, -1); paintPp(); return; }
    if (payPwd.length >= 6) return;
    payPwd += k;
    paintPp();
    if (payPwd.length === 6) ppSubmit(payPwd);
  }
  function ppSubmit(code) {
    ppHint('');
    if (ppStep === 'old') {
      api('/me/paypassword/verify', { method: 'POST', body: JSON.stringify({ password: code }) })
        .then(function () { ppOld = code; payPwd = ''; ppStep = 'new1'; paintPp(); })
        .catch(function (e) { payPwd = ''; paintPp(); ppShake(); ppHint(e.message || '支付密码不正确'); });
      return;
    }
    if (ppStep === 'set1' || ppStep === 'new1') {
      ppTmp = code; payPwd = '';
      ppStep = (ppStep === 'set1') ? 'set2' : 'new2';
      paintPp();
      return;
    }
    // set2 / new2：两次要对得上
    if (code !== ppTmp) {
      payPwd = ''; ppStep = (ppStep === 'set2') ? 'set1' : 'new1'; paintPp(); ppShake();
      ppHint('两次输入不一样，重新来一次');
      return;
    }
    var body = { password: code };
    if (ppOld) body.current = ppOld;
    api('/me/paypassword', { method: 'POST', body: JSON.stringify(body) })
      .then(function () {
        payHasPwd = true;
        if ($('secPayPwdVal')) $('secPayPwdVal').textContent = '已设置';
        paintPayPwdTip();
        ppHint('支付密码已保存', true);
        setTimeout(function () { $('ppScreen').hidden = true; ppHint(''); }, 700);
      })
      .catch(function (e) {
        payPwd = ''; ppStep = 'old'; ppOld = ''; paintPp(); ppShake();
        ppHint(e.message || '保存失败');
      });
  }

  function bindPaySheet() {
    $('okDone').addEventListener('click', function () { $('payOkScreen').hidden = true; });
    $('payX').addEventListener('click', cancelTransfer);
    $('payFace').addEventListener('click', function () { payConfirm({ face: true }); });
    $('payPwdTip').addEventListener('click', function () {
      if ((Number(payValue) || 0) > balanceOf()) { openRechargeSheet(); return; }
      if (!payHasPwd) { cancelTransfer(); openSecurityCenter(true); }
    });
    $('payChange').addEventListener('click', openPayMethodSheet);
    $('pmX').addEventListener('click', closePayMethodSheet);
    $('pmRecharge').addEventListener('click', openRechargeSheet);
    $('pmMask').addEventListener('click', function (e) { if (e.target === $('pmMask')) closePayMethodSheet(); });
    $('pmList').addEventListener('click', function (e) {
      var row = e.target.closest('[data-pm]');
      if (row) pickPayMethod(row.getAttribute('data-pm'));
    });
    $('pmHead').addEventListener('touchstart', function (e) {
      pmDrag.on = true; pmDrag.y0 = e.touches[0].clientY; pmDrag.dy = 0;
      $('pmSheet').classList.add('is-drag');
    }, { passive: true });
    $('pmHead').addEventListener('touchmove', function (e) {
      if (!pmDrag.on) return;
      pmDrag.dy = Math.max(0, e.touches[0].clientY - pmDrag.y0);
      $('pmSheet').style.transform = 'translateY(' + pmDrag.dy + 'px)';
    }, { passive: true });
    var pmEnd = function () {
      if (!pmDrag.on) return;
      pmDrag.on = false;
      var over = pmDrag.dy > 90;
      $('pmSheet').classList.remove('is-drag');
      $('pmSheet').style.transform = '';
      if (over) closePayMethodSheet();
    };
    $('pmHead').addEventListener('touchend', pmEnd, { passive: true });
    $('pmHead').addEventListener('touchcancel', pmEnd, { passive: true });
    $('payMask').addEventListener('click', function (e) { if (e.target === $('payMask')) cancelTransfer(); });
    $('payPad').addEventListener('click', function (e) {
      var k = e.target.closest('[data-pk]');
      if (!k) return;
      payPwdKey(k.getAttribute('data-pk'));
    });
    // 按住面板顶部往下拖 → 跟手移动，松手超过 90px 就关掉
    $('payHead').addEventListener('touchstart', function (e) {
      payDrag.on = true; payDrag.y0 = e.touches[0].clientY; payDrag.dy = 0;
      $('paySheet').classList.add('is-drag');
    }, { passive: true });
    $('payHead').addEventListener('touchmove', function (e) {
      if (!payDrag.on) return;
      payDrag.dy = Math.max(0, e.touches[0].clientY - payDrag.y0);
      $('paySheet').style.transform = 'translateY(' + payDrag.dy + 'px)';
    }, { passive: true });
    var end = function () {
      if (!payDrag.on) return;
      payDrag.on = false;
      var over = payDrag.dy > 90;
      $('paySheet').classList.remove('is-drag');
      $('paySheet').style.transform = '';
      if (over) cancelTransfer();
    };
    $('payHead').addEventListener('touchend', end, { passive: true });
    $('payHead').addEventListener('touchcancel', end, { passive: true });
  }

  /* 安全中心 / 支付密码页的绑定 */
  function bindSecurityCenter() {
    $('secBack').addEventListener('click', function () { $('secScreen').hidden = true; });
    $('secPayPwdRow').addEventListener('click', function () { openPayPwdPage(); });
    $('ppBack').addEventListener('click', function () { $('ppScreen').hidden = true; });
    $('ppPad').addEventListener('click', function (e) {
      var k = e.target.closest('[data-pp]');
      if (!k) return;
      ppKey(k.getAttribute('data-pp'));
    });
  }

  function bindTransferPage() {
    $('tfBack').addEventListener('click', function () { cancelTransfer(); $('transferScreen').hidden = true; });
    // 点金额区域，数字键盘才弹出来
    $('tfAmountBox').addEventListener('click', function () {
      $('tfPad').classList.add('is-on');
      $('tfAmountLine').classList.add('is-focus');   // 出现绿色闪烁光标
    });
    $('tfPad').addEventListener('click', function (e) {
      var b = e.target.closest('[data-k]'); if (!b) return;
      tfPress(b.getAttribute('data-k'));
    });
    $('tfSend').addEventListener('click', sendTransfer);
    $('tfNoteRow').addEventListener('click', openNoteSheet);
  }

  /* 转账说明：半屏面板，可以往下滑关闭 */
  var ntDrag = { y0: 0, dy: 0, on: false };

  function openNoteSheet() {
    $('ntInput').value = tfNote || '';
    paintNoteCount();
    var sheet = $('ntSheet');
    sheet.classList.remove('is-drag');
    sheet.style.transform = '';
    $('ntMask').hidden = false;
    setTimeout(function () { try { $('ntInput').focus(); } catch (e) { } }, 120);
  }

  function closeNoteSheet(save) {
    var sheet = $('ntSheet');
    if (save) {
      tfNote = ($('ntInput').value || '').trim().slice(0, 60);
      $('tfNoteRow').textContent = tfNote || '添加转账说明';
      $('tfNoteRow').classList.toggle('is-set', !!tfNote);
    }
    sheet.classList.remove('is-drag');
    sheet.style.transform = '';
    $('ntMask').hidden = true;
    try { $('ntInput').blur(); } catch (e) { }
  }

  function paintNoteCount() {
    var n = ($('ntInput').value || '').length;
    $('ntCount').textContent = n + '/60';
  }

  function bindNoteSheet() {
    $('ntDone').addEventListener('click', function () { closeNoteSheet(true); });
    $('ntInput').addEventListener('input', paintNoteCount);
    $('ntInput').addEventListener('keydown', function (e) { if (e.key === 'Enter') closeNoteSheet(true); });
    $('ntMask').addEventListener('click', function (e) { if (e.target === $('ntMask')) closeNoteSheet(true); });

    // 按住面板往下拖 → 跟手移动，松手超过 90px 就关掉
    $('ntGrab').addEventListener('touchstart', function (e) {
      ntDrag.on = true; ntDrag.y0 = e.touches[0].clientY; ntDrag.dy = 0;
      $('ntSheet').classList.add('is-drag');
    }, { passive: true });
    $('ntGrab').addEventListener('touchmove', function (e) {
      if (!ntDrag.on) return;
      ntDrag.dy = Math.max(0, e.touches[0].clientY - ntDrag.y0);
      $('ntSheet').style.transform = 'translateY(' + ntDrag.dy + 'px)';
    }, { passive: true });
    var end = function () {
      if (!ntDrag.on) return;
      ntDrag.on = false;
      var over = ntDrag.dy > 90;
      $('ntSheet').classList.remove('is-drag');
      $('ntSheet').style.transform = '';
      if (over) closeNoteSheet(true);
    };
    $('ntGrab').addEventListener('touchend', end, { passive: true });
    $('ntGrab').addEventListener('touchcancel', end, { passive: true });
  }

  /* ---------------------------------------------------------- 设置状态（后台配的，都能点） */
  function loadStatuses() {
    return api('/statuses').then(function (d) {
      S.statusCats = (d.categories || []);
      if (!$('statusScreen').hidden) renderStatusPage();
      paintStatusChip();
    }).catch(function () { });
  }

  function paintStatusChip() {
    var chip = $('chipStatus');
    if (!chip) return;
    var me = S.me || {};
    if (me.moodText) {
      chip.innerHTML = '<span class="chip-ic">' + esc(me.moodIcon || '🙂') + '</span>' + esc(me.moodText);
      /* 这里以前把文字设成「状态色本身」，而它背后的整页渐变也是同一个颜色，
         叠在一起根本看不清。现在交给 CSS 的 .me-block.has-mood 规则：白字 + 白色玻璃胶囊。 */
      chip.style.background = '';
      chip.style.borderColor = '';
      chip.style.color = '';
    } else {
      chip.innerHTML = '<span class="chip-plus">＋</span>状态';
      chip.style.background = '';
      chip.style.borderColor = '';
      chip.style.color = '';
    }
  }

  /* 设了状态 → 「我」页头像卡跟着变彩色（颜色就是那个状态的颜色） */
  function applyStatusTheme() {
    var block = document.querySelector('#profileTop');
    if (!block) return;
    var me = S.me || {};
    var c = me.moodColor || '';
    if (me.moodText && c) {
      var c2 = me.moodColor2 || shadeColor(c, -26);
      block.style.background = 'linear-gradient(155deg, ' + c + ' 0%, ' + c2 + ' 100%)';
      block.classList.add('has-mood');
      // 头像那块彩色直接铺满整页：整页背景用状态的渐变，资料卡融进去
      var mePage = document.querySelector('[data-page="me"]');
      var meScroll = mePage ? mePage.querySelector('.me-scroll') : null;
      // 只有上半部分是状态色，越往下越淡，到底部就回到正常底色（底部不留颜色）
      if (mePage) {
        // 渐变用 CSS 变量 + class 控制（浅色淡到页面底色、深色淡到全透明），
        // 这样切换深浅色的时候不用重新算，深色模式也不会被 .wx-page 的 transparent 盖掉
        var c2a = /^#[0-9a-fA-F]{6}$/.test(c2) ? (c2 + '00') : 'rgba(0,0,0,0)';
        mePage.style.setProperty('--mood-c', c);
        mePage.style.setProperty('--mood-c2', c2);
        mePage.style.setProperty('--mood-c2a', c2a);
        mePage.classList.add('has-mood-bg');
      }
      if (meScroll) meScroll.style.background = 'transparent';
      block.style.background = 'transparent';
      var av = $('meAvatar');
      if (av) av.style.boxShadow = '0 0 0 3px rgba(255,255,255,.85), 0 6px 18px rgba(0,0,0,.28)';
      var chip = $('chipStatus');
      if (chip) chip.style.color = '#fff';
    } else {
      block.style.background = '';
      block.classList.remove('has-mood');
      var mePage2 = document.querySelector('[data-page="me"]');
      var meScroll2 = mePage2 ? mePage2.querySelector('.me-scroll') : null;
      if (mePage2) {
        mePage2.classList.remove('has-mood-bg');
        mePage2.style.removeProperty('--mood-c');
        mePage2.style.removeProperty('--mood-c2');
        mePage2.style.removeProperty('--mood-c2a');
        mePage2.style.backgroundImage = '';
      }
      if (meScroll2) meScroll2.style.background = '';
      var av2 = $('meAvatar');
      if (av2) av2.style.boxShadow = '';
    }
  }

  /* 颜色加深/变浅（-26 就是暗一点），用来做渐变的第二档 */
  function shadeColor(hex, percent) {
    var h = String(hex || '').replace('#', '');
    if (h.length !== 6) return hex;
    var num = parseInt(h, 16);
    var r = (num >> 16) & 255, g = (num >> 8) & 255, b = num & 255;
    var f = function (v) { return Math.max(0, Math.min(255, Math.round(v + (percent / 100) * 255))); };
    return '#' + [f(r), f(g), f(b)].map(function (v) { return v.toString(16).padStart(2, '0'); }).join('');
  }

  function openStatusPage() {
    $('statusScreen').hidden = false;
    renderStatusPage();
    if (!S.statusCats) loadStatuses();
  }

  function renderStatusPage() {
    var box = $('stScroll');
    if (!box) return;
    var me = S.me || {};
    var html = '';
    if (me.moodText) {
      html += '<div class="st-cur"><span class="ic">' + esc(me.moodIcon || '🙂') + '</span>' +
        '<span>当前状态：' + esc(me.moodText) + '</span>' +
        '<button class="cut" id="stClear">取消状态</button></div>';
    }
    (S.statusCats || []).forEach(function (cat) {
      html += '<div class="st-cat"><div class="st-cat-name">' + esc(cat.name) + '</div><div class="st-grid">' +
        (cat.items || []).map(function (it) {
          var on = me.moodText === it.label ? ' is-on' : '';
          var c = it.color || cat.color || '#6f8a38';
          var c2 = it.color2 || c;
          // 已经有状态时，其它状态先锁住：要结束当前状态才能换
          var locked = me.moodText && !on ? ' is-locked' : '';
          return '<button class="st-item' + on + locked + '" data-status="' + esc(it.label) + '" data-ic="' + esc(it.icon) + '" data-color="' + esc(c) + '" data-color2="' + esc(c2) + '" style="background:linear-gradient(160deg,' + esc(c) + ',' + esc(c2) + ')">' +
            '<span class="ic">' + esc(it.icon) + '</span><span class="tx">' + esc(it.label) + '</span></button>';
        }).join('') + '</div></div>';
    });
    if (!(S.statusCats || []).length) html += '<div class="st-cur">后台还没配状态，去「后台 → 状态」加几个</div>';
    html += '<div class="st-foot" id="stPresence"><span>在线状态：在线 / 忙碌 / 离开 / 隐身</span><span class="me-arrow">›</span></div>';
    box.innerHTML = html;
    paintStatusPageBg();

    box.querySelectorAll('[data-status]').forEach(function (b) {
      b.addEventListener('click', function () {
        var label = b.getAttribute('data-status');
        var cur = (S.me && S.me.moodText) || '';
        if (cur && cur !== label) {
          toast('先结束当前状态「' + cur + '」，才能换新的');
          return;
        }
        if (cur === label) return;      // 点自己没反应
        setMood(label, b.getAttribute('data-ic'), b.getAttribute('data-color'), b.getAttribute('data-color2'));
      });
    });
    if ($('stClear')) $('stClear').addEventListener('click', function () { setMood('', '', '', ''); });
    if ($('stPresence')) $('stPresence').addEventListener('click', function () { openStatusSheet(); });
  }

  function setMood(text, icon, color, color2) {
    api('/me', { method: 'PATCH', body: JSON.stringify({ moodText: text, moodIcon: icon, moodColor: color || '', moodColor2: color2 || '' }) })
      .then(function (d) {
        if (d && d.user) S.me = d.user;
        paintStatusChip();
        renderStatusPage();
        renderProfile();
        applyStatusTheme();
        toast(text ? '状态已设为「' + text + '」' : '已结束状态');
      })
      .catch(function (e) { toast(e.message || '设置失败'); });
  }

  /* 状态面板的背景：换哪个状态，整块面板就变成那个状态的渐变色 */
  function paintStatusPageBg() {
    var screen = $('statusScreen');
    var scroll = $('stScroll');
    if (!screen || !scroll) return;
    var me = S.me || {};
    var c = me.moodText ? (me.moodColor || '') : '';
    if (!c) {
      screen.style.backgroundColor = '';
      scroll.style.backgroundImage = '';
      return;
    }
    var c2 = me.moodColor2 || shadeColor(c, -26);
    screen.style.backgroundColor = c;
    scroll.style.backgroundImage = 'linear-gradient(180deg, ' + c + ' 0%, ' + c2 + ' 62%, ' + c2 + ' 100%)';
  }

  function bindStatusPage() {
    $('stBack').addEventListener('click', function () { $('statusScreen').hidden = true; });
  }

  /* ---------------------------------------------------------- 手机号整页 */
  var phoneShown = false;
  function openPhonePage() {
    phoneShown = false;
    renderPhonePage();
    $('phoneScreen').hidden = false;
  }

  function maskPhone(p) {
    var s = String(p || '');
    if (!s) return '';
    return s.length >= 7 ? (s.slice(0, 3) + '******' + s.slice(-2)) : s;
  }

  function renderPhonePage() {
    if (!$('phValue')) return;
    var me = S.me || {};
    var phone = String(me.phone || '');
    $('phLabel').textContent = phone ? '已绑定手机号' : '未绑定手机号';
    $('phValue').textContent = phone ? (phoneShown ? phone : maskPhone(phone)) : '未绑定';
    $('phToggle').hidden = !phone;
    $('phToggle').textContent = phoneShown ? '隐藏' : '显示';

    var chk = canChangePhone();
    $('phNote').textContent = chk.ok
      ? '更换手机号后，可以用来找回密码、接收安全提醒；一年只能更换一次。'
      : ('手机号一年只能更换一次，下次可更换：' + chk.msg.replace('手机号一年只能改一次，下次可改：', ''));
    var btn = $('phChange');
    btn.textContent = phone ? '更换手机号' : '绑定手机号';
    btn.classList.toggle('is-off', false);
  }

  function bindPhonePage() {
    $('phBack').addEventListener('click', function () { $('phoneScreen').hidden = true; });
    $('phToggle').addEventListener('click', function () { phoneShown = !phoneShown; renderPhonePage(); });
    $('phContacts').addEventListener('click', function () { toast('上传通讯录找朋友：手机端暂未开放，可用微信号搜索加好友'); });
    $('phChange').addEventListener('click', function () {
      var chk = canChangePhone();
      if (!chk.ok) { toast(chk.msg); return; }
      askInput((S.me && S.me.phone) ? '更换手机号（一年一次）' : '绑定手机号', '', 20, function (v) {
        if (!v) return;
        saveMe({ phone: v }, '手机号已更新，一年内不能再换').then(function () {
          phoneShown = true;
          renderPhonePage();
        });
      });
    });
  }

  function canChangePhone() {
    var at = S.me && S.me.phoneUpdatedAt ? new Date(S.me.phoneUpdatedAt).getTime() : 0;
    if (!at) return { ok: true };
    var YEAR = 365 * 24 * 60 * 60 * 1000;
    var left = at + YEAR - Date.now();
    if (left <= 0) return { ok: true };
    var can = new Date(at + YEAR);
    var days = Math.ceil(left / 86400000);
    return { ok: false, msg: '手机号一年只能改一次，下次可改：' + (can.getMonth() + 1) + '月' + can.getDate() + '日（还有 ' + days + ' 天）' };
  }

  var askHandler = null;
  function askInput(title, value, maxLength, cb) {
    $('askTitle').textContent = title;
    var input = $('askInput');
    input.value = value == null ? '' : value;
    input.maxLength = maxLength || 24;
    $('askMask').hidden = false;
    askHandler = cb || null;
    setTimeout(function () { try { input.focus(); input.select(); } catch (e) { } }, 60);
  }

  function closeAsk() { $('askMask').hidden = true; askHandler = null; }

  /* 改资料：改完立刻 PATCH 到服务端，界面同步刷新 */
  function saveMe(patch, okMsg) {
    return api('/me', { method: 'PATCH', body: JSON.stringify(patch) }).then(function (d) {
      if (d && d.user) S.me = d.user;
      fillMe();
      if (okMsg) toast(okMsg);
    }).catch(function (e) { toast(e.message || '保存失败'); });
  }

  /* ---------------------------------------------------------- 标签切换 */
  function switchTab(tab) {
    S.tab = tab;
    try { localStorage.setItem('wx-tab', tab); } catch (e) { }
    document.querySelectorAll('.wx-page').forEach(function (p) {
      p.hidden = p.getAttribute('data-page') !== tab;
    });
    document.querySelectorAll('.wx-tab').forEach(function (t) {
      t.classList.toggle('is-active', t.getAttribute('data-tab') === tab);
    });
    if (tab === 'me') { loadMomentsBadge(); loadMePage(); }
    /* 点开「发现」也顺手刷一下朋友圈红点（长连接漏推送时也能补上） */
    if (tab === 'discover') { loadDiscover(); }
  }

  /* ---------------------------------------------------------- 下拉刷新（就地刷新，不跳回主页） */
  var ptrStart = 0, ptrPulling = false, ptrY = 0, ptrBusy = false;

  function topScroller() {
    if (!$('chatScreen').hidden) return $('messages');
    if (!$('momentsScreen').hidden) return $('momentsScroll');
    if (!$('stickerScreen').hidden) return document.querySelector('.stk-scroll');
    if (!$('profileScreen').hidden) return document.querySelector('.pf-scroll');
    if (!$('newFriendsScreen').hidden) return $('requestList');
    var page = document.querySelector('.wx-page:not([hidden])');
    if (!page) return null;
    return page.querySelector('.me-scroll') || page.querySelector('.wx-list') || page;
  }

  function setPtr(y, busy) {
    var el = $('ptr');
    if (!el) return;
    if (y <= 0 && !busy) { el.classList.remove('is-show'); return; }
    el.classList.add('is-show');
    el.classList.toggle('is-busy', !!busy);
    // 球跟着手指：越拉越大、越拉转得越多
    var k = Math.min(1, y / 70);
    el.style.setProperty('--ptr-scale', (0.68 + k * 0.42).toFixed(2));
    el.style.setProperty('--ptr-rot', Math.round(y * 3.2) + 'deg');
  }

  /* 刷新当前所在的页面（不换页、不重载） */
  function refreshCurrent() {
    if (ptrBusy) return;
    ptrBusy = true;
    setPtr(70, true);
    var jobs = [];
    if (!$('momentsScreen').hidden) jobs.push(loadMoments());
    else if (!$('stickerScreen').hidden) jobs.push(loadStickers());
    else if (!$('profileScreen').hidden) jobs.push(refreshMe());
    else if (!$('newFriendsScreen').hidden) jobs.push(loadRequests());
    else if (!$('chatScreen').hidden && S.activeChat) jobs.push(reloadActiveChat());
    else if (S.tab === 'contacts') jobs.push(loadContacts());
    else if (S.tab === 'discover') jobs.push(loadDiscover());
    else if (S.tab === 'me') jobs.push(refreshMe(), loadMomentsBadge(), loadMePage());
    else jobs.push(loadChats());
    jobs.push(loadStickers(), loadGifts(), loadPlusPanel());
    Promise.all(jobs.map(function (p) { return Promise.resolve(p).catch(function () { }); })).then(function () {
      setTimeout(function () {
        ptrBusy = false;
        setPtr(0);
      }, 220);
    });
  }

  function refreshMe() {
    return api('/me').then(function (d) {
      if (d && d.user) { S.me = d.user; fillMe(); }
    }).catch(function () { });
  }

  function reloadActiveChat() {
    if (!S.activeChat) return Promise.resolve();
    return api('/chats/' + encodeURIComponent(S.activeChat) + '/messages?limit=60').then(function (d) {
      S.messages[S.activeChat] = d.messages || [];
      renderMessages();
      markRead(S.activeChat);
    }).catch(function () { });
  }

  function loadRequests() {
    return loadContacts().then(function () { renderRequests(); }).catch(function () { });
  }

  function bindPullRefresh() {
    var app = $('app');
    var coverBaseH = 0;
    app.addEventListener('touchstart', function (e) {
      if (e.touches.length !== 1) { ptrPulling = false; return; }
      // 下拉刷新只在朋友圈页生效，其它页面不动
      if ($('momentsScreen').hidden) { ptrPulling = false; return; }
      var sc = topScroller();
      if (!sc || sc.scrollTop > 2) { ptrPulling = false; return; }
      var cover = $('momentsCover');
      coverBaseH = cover ? Math.round(cover.getBoundingClientRect().height) : 0;
      ptrStart = e.touches[0].clientY;
      ptrY = 0;
      ptrPulling = true;
    }, { passive: true });
    app.addEventListener('touchmove', function (e) {
      if (!ptrPulling) return;
      var dy = e.touches[0].clientY - ptrStart;
      if (dy <= 0) { ptrY = 0; setPtr(0); return; }
      ptrY = dampPull(dy, 0.85);          // 朋友圈也能无限下拉
      setPtr(ptrY, false);
      stretchCover(ptrY, coverBaseH);      // 封面跟着往下拉长
    }, { passive: true });
    app.addEventListener('touchend', function () {
      if (!ptrPulling) return;
      ptrPulling = false;
      stretchCover(0, coverBaseH);
      if (ptrY >= 60) refreshCurrent();
      else setPtr(0);
    }, { passive: true });
    app.addEventListener('touchcancel', function () { ptrPulling = false; stretchCover(0, coverBaseH); setPtr(0); }, { passive: true });
  }

  /* 「我」页：头像卡背景往下拉长（松手弹回），和朋友圈封面一个手感 */
  /* 无限下拉用的「越拉越沉」函数：没有上限，只是越来越费力，手感像橡皮筋 */
  function dampPull(dy, k) {
    var out = 0, left = dy, f = k, step = 110;
    while (left > 0) {
      var take = Math.min(step, left);
      out += take * f;
      left -= take;
      f *= 0.74;
      if (f < 0.12) f = 0.12;
    }
    return out;
  }

  function bindMeStretch() {
    var app = $('app');
    var start = 0, pulling = false, base = 0, y = 0;
    app.addEventListener('touchstart', function (e) {
      if (e.touches.length !== 1) { pulling = false; return; }
      if (S.tab !== 'me') { pulling = false; return; }
      if (!$('profileScreen').hidden || !$('statusScreen').hidden || !$('phoneScreen').hidden || !$('settingsScreen').hidden) { pulling = false; return; }
      var sc = document.querySelector('[data-page="me"] .me-scroll');
      if (!sc || sc.scrollTop > 2) { pulling = false; return; }
      var card = $('profileTop');
      if (!card) { pulling = false; return; }
      base = Math.round(card.getBoundingClientRect().height);
      start = e.touches[0].clientY;
      y = 0;
      pulling = true;
    }, { passive: true });
    app.addEventListener('touchmove', function (e) {
      if (!pulling) return;
      var dy = e.touches[0].clientY - start;
      if (dy <= 0) { y = 0; setMeStretch(0, base); return; }
      y = dampPull(dy, 0.9);              // 可以一直拉，没有上限
      setMeStretch(y, base);
    }, { passive: true });
    var end = function () {
      if (!pulling) return;
      pulling = false;
      setMeStretch(0, base);
    };
    app.addEventListener('touchend', end, { passive: true });
    app.addEventListener('touchcancel', end, { passive: true });
  }

  function setMeStretch(y, base) {
    var card = $('profileTop');
    if (!card || !base) return;
    if (y > 0) {
      card.classList.add('is-pulling');
      card.style.height = Math.round(base + y) + 'px';
    } else {
      card.classList.remove('is-pulling');
      card.style.height = base + 'px';
      setTimeout(function () {
        if (!card.classList.contains('is-pulling')) card.style.height = '';
      }, 300);
    }
  }

  /* 4 个前置页面（微信 / 通讯录 / 发现）顶部无限下拉：
     列表已经在最顶上还继续往下拉时，整块内容跟手往下走（越拉越沉、不设上限），
     松手弹回。和「我」页拉状态卡、朋友圈拉封面是同一个手感；子页面不参与，避免打架。 */
  function bindTopBounce() {
    var app = $('app');
    if (!app) return;
    var MAP = {
      chats: '[data-page="chats"] .wx-list',
      contacts: '[data-page="contacts"] .wx-list',
      discover: '[data-page="discover"] .me-scroll'
    };
    var el = null, start = 0, pulling = false, back = 0;
    /* 下拉时顶栏那几个字（微信(N) + ＋号）1:1 跟着手往下滑，搜索框不在其中（它不动） */
    function setPullTitle(y) {
      var nav = document.querySelector('.wx-page[data-page="chats"] .wx-nav');
      if (!nav) return;
      nav.style.setProperty('--chat-pull', Math.round(y || 0) + 'px');
    }
    function resetBounce() {
      if (!el) return;
      var target = el;
      el = null;
      target.style.transition = 'transform 0.26s cubic-bezier(0.2, 0.9, 0.3, 1)';
      target.style.transform = '';
      setPullTitle(0);
      setTimeout(function () { target.style.transition = ''; }, 300);
    }
    app.addEventListener('touchstart', function (e) {
      el = null; pulling = false;
      if (e.touches.length !== 1) return;
      var sel = MAP[S.tab];
      if (!sel) return;
      if (document.querySelector('.wx-chat:not([hidden]), .wx-moments:not([hidden]), .wx-call:not([hidden])')) return;
      var sc = document.querySelector(sel);
      if (!sc || sc.scrollTop > 0) return;      /* 只有滚到最顶上才允许下拉 */
      el = sc; start = e.touches[0].clientY; back = 0; pulling = true;
      sc.style.transition = 'none';
      sc.style.overscrollBehavior = 'contain';
    }, { passive: true });
    app.addEventListener('touchmove', function (e) {
      if (!pulling || !el) return;
      var dy = e.touches[0].clientY - start;
      if (dy <= 0) { if (back) { back = 0; el.style.transform = ''; } return; }
        back = dampPull(dy, 0.55);
        el.style.transform = 'translateY(' + back + 'px)';
        setPullTitle(back);
      /* 注意：这个监听必须是 passive（不能 preventDefault），
         否则 iOS 每次滚动都要等主线程的 JS 跑完才动，滚起来就「不丝滑」。
         橡皮筋已经在 CSS 里用 overscroll-behavior 关掉了，不会和这里打架。 */
    }, { passive: true });
    var end = function () { if (!pulling) return; pulling = false; resetBounce(); };
    app.addEventListener('touchend', end, { passive: true });
    app.addEventListener('touchcancel', end, { passive: true });
  }

  /* 下拉时封面往下长（松手弹回原高度） */
  function stretchCover(y, baseH) {
    var cover = $('momentsCover');
    if (!cover || !baseH) return;
    if (y > 0) {
      cover.classList.add('is-pulling');
      cover.style.height = Math.round(baseH + y * 1.15) + 'px';   // 封面也多拉一点
    } else {
      cover.classList.remove('is-pulling');
      cover.style.height = baseH + 'px';
      setTimeout(function () {
        if (!cover.classList.contains('is-pulling')) cover.style.height = '';
      }, 300);
    }
  }

  /* ---------------------------------------------------------- 会话列表 */
  function loadChats() {
    var wantSync = false;
    try { wantSync = localStorage.getItem('wx-agree') === '1'; } catch (e) { }
    var url = '/chats' + ((wantSync && !S.syncedOnce) ? '?withMessages=1&syncChats=12&syncLimit=30' : '');
    return api(url).then(function (d) {
      S.chats = d.chats || [];
      // 登录时勾了「同步最近的聊天记录」→ 最近会话的消息一起带回来，并缓存到本机
      if (d.sync && d.sync.chats) applySync(d.sync);
      renderChats();
    });
  }

  /* 真正同步：最近会话的消息写进内存 + 本机缓存，下次打开立刻能看到 */
  function applySync(sync) {
    var total = 0, n = 0;
    (sync.chats || []).forEach(function (c) {
      var list = (c.messages || []).slice();
      if (!S.messages[c.id] || S.messages[c.id].length < list.length) S.messages[c.id] = list;
      total += list.length;
      n += 1;
    });
    S.syncedOnce = true;
    S.lastSyncAt = sync.syncedAt || new Date().toISOString();
    saveMsgCache();
    if (n) toast('已同步最近 ' + n + ' 个会话、' + total + ' 条消息');
  }

  function cacheKey() { return 'wx-msgs:' + ((S.me && S.me.username) || 'me'); }
  function saveMsgCache() {
    try {
      var slim = {};
      Object.keys(S.messages || {}).forEach(function (k) { slim[k] = (S.messages[k] || []).slice(-30); });
      localStorage.setItem(cacheKey(), JSON.stringify({ at: Date.now(), messages: slim }));
    } catch (e) { }
  }
  function loadMsgCache() {
    try {
      var raw = localStorage.getItem(cacheKey());
      if (!raw) return;
      var obj = JSON.parse(raw);
      if (obj && obj.messages) {
        Object.keys(obj.messages).forEach(function (k) {
          if (!S.messages[k] || !S.messages[k].length) S.messages[k] = obj.messages[k];
        });
        S.cachedAt = obj.at;
      }
    } catch (e) { }
  }

  function lastPreview(c) {
    var last = c.lastMessage;
    if (!last) return '开始聊天';
    if (!last.preview) return '';   /* 转账不进会话列表：没有别的消息时预览留空，不显示「我：」 */
    var prefix = last.senderId === S.me.id ? '我：' : '';
    return prefix + (last.preview || '');
  }

  function renderChats() {
    var kw = ($('chatSearch').value || '').trim().toLowerCase();
    var list = S.chats.filter(function (c) { return !kw || (c.title || '').toLowerCase().indexOf(kw) >= 0; });
    var box = $('chatList');
    if (!list.length) { box.innerHTML = '<div class="wx-empty">还没有会话</div>'; }
    else {
      box.innerHTML = list.map(function (c) {
        var unread = c.unread > 0 ? '<span class="wx-unread">' + c.unread + '</span>' : '';
        var face = c.avatar ? '<img src="' + esc(c.avatar) + '" alt="" loading="lazy" decoding="async">' : esc(initials(c.title));
      return '<div class="wx-row' + (c.pinned ? ' is-pinned' : '') + '" data-chat="' + esc(c.id) + '">' +
          '<div class="wx-row-slide">' +            /* 左滑时这一层往左移 */
            '<div class="wx-avatar">' + face + '</div>' +
            unread +                                 /* 红色角标挂在头像右上角 */
            '<div class="wx-row-main">' +
              '<div class="wx-row-top"><span class="wx-row-name">' + esc(c.title) + '</span>' +
              '<span class="wx-row-time">' + esc(chatTime(c.updatedAt || (c.lastMessage && c.lastMessage.createdAt) || '')) + '</span></div>' +
              '<div class="wx-row-preview">' + esc(lastPreview(c)) + '</div>' +
            '</div>' +
          '</div>' +
          /* 左滑露出来的三个操作（和微信一致） */
          '<div class="wx-row-actions">' +
            '<button type="button" data-act="unread" data-id="' + esc(c.id) + '">标为未读</button>' +
            /* 微信是一整条长条：正常「不显示该聊天」，再往里滑变「清空记录同时不显示聊天」（红） */
            '<button type="button" data-act="hide" data-id="' + esc(c.id) + '">' +
              '<span class="ra-1">不显示</span>' +
              '<span class="ra-2">不显示该聊天</span>' +
              '<span class="ra-3">清空记录同时不显示聊天</span>' +
            '</button>' +
            '<button type="button" data-act="del" data-id="' + esc(c.id) + '">' +
              '<span class="rd-1">删除</span>' +
              '<span class="rd-2">清空记录同时不显示聊天</span>' +
            '</button>' +
          '</div>' +
        '</div>';
      }).join('');
    }
    var total = S.chats.reduce(function (a, c) { return a + (c.unread || 0); }, 0);
    setTabBadge('tabBadge', total);
    // 顶部标题也带上未读条数：微信(3)
    var title = $('navTitle');
    if (title) title.textContent = total > 0 ? '微信(' + total + ')' : '微信';
  }

  /** 底部标签的红点数字（微信：会话 / 通讯录 / 发现 都会有） */
  function setTabBadge(id, n, dot) {
    var el = document.getElementById(id);
    if (!el) return;
    var count = Number(n) || 0;
    el.hidden = count <= 0;
    /* dot = true：通讯录 / 发现 用微信那种纯红点（不带数字） */
    el.classList.toggle('is-dot', !!dot);
    if (dot) { el.classList.remove('is-dots'); el.textContent = ''; return; }
    // 底部角标：99 以内显示数字，超过 99 就只显示三个点
    var dots = count > 99;
    el.textContent = dots ? '…' : String(count);
    el.classList.toggle('is-dots', dots);
  }

  /* ---------------------------------------------------------- 通讯录 */
  /* ---------------- 新的朋友 ---------------- */
  function openNewFriends() {
    $('newFriendsScreen').hidden = false;
    renderRequests();
  }

  function renderRequests() {
    var list = S.incoming || [];
    var box = $('requestList');
    if (!list.length) {
      box.innerHTML = '<div class="wx-empty">没有新的好友申请</div>';
      return;
    }
    box.innerHTML = '<div class="wx-req-title">好友申请</div>' + list.map(function (r) {
      var face = r.avatar ? '<img src="' + esc(r.avatar) + '" alt="" loading="lazy" decoding="async">' : esc(initials(r.nickname));
      return '<div class="wx-row wx-req">' +
        '<div class="wx-avatar">' + face + '</div>' +
        '<div class="wx-row-main"><div class="wx-row-top"><span class="wx-row-name">' + esc(r.nickname) + '</span></div>' +
        '<div class="wx-row-preview">请求加你为好友</div></div>' +
        '<div class="wx-req-btns">' +
          '<button class="wx-mini is-ok" data-accept="' + esc(r.requestId) + '">接受</button>' +
          '<button class="wx-mini" data-reject="' + esc(r.requestId) + '">拒绝</button>' +
        '</div></div>';
    }).join('');
  }

  function respondRequest(requestId, accept) {
    api('/friends/respond', { method: 'POST', body: JSON.stringify({ requestId: requestId, accept: !!accept }) })
      .then(function () {
        toast(accept ? '已添加好友' : '已拒绝');
        return loadContacts();
      })
      .then(function () { renderRequests(); })
      .catch(function (e) { toast(e.message); });
  }

  function loadContacts() {
    return api('/contacts').then(function (d) {
      S.friends = d.friends || [];
      S.incoming = d.incoming || [];
      renderContacts();
    });
  }

  function renderContacts() {
    /* 通讯录：显示「几条好友申请」的数字（用户要求）；发现那边才是纯红点 */
    setTabBadge('tabBadgeContacts', (S.incoming || []).length);
    if ($('chipFriends')) $('chipFriends').textContent = (S.friends || []).length + ' 个朋友';
    var box = $('contactList');
    var kw = ($('ctSearch') ? $('ctSearch').value : '').trim().toLowerCase();
    var rows = '';

    if (!kw) {
      // 顶部几个功能项（和参考图一致：新的朋友 / 仅聊天的朋友 / 标签 / 服务号 / 企业微信联系人 / 我的企业）
      var nNew = (S.incoming || []).length;
      rows += '<div class="ct-funcs">' +
        '<div class="ct-func" id="newFriends"><span class="ct-fico" style="background:#f5a23d">' +
          '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="10.4" cy="8.6" r="3.4"/><path d="M4.4 19c0-3 2.7-5 6-5s6 2 6 5"/><path d="M18.4 8.4v4.6M16.1 10.7h4.6"/></svg>' +
        '</span><span class="ct-flabel">新的朋友</span>' + (nNew ? '<span class="wx-unread">' + nNew + '</span>' : '') + '</div>' +
        '<div class="ct-func" id="ctChatOnly"><span class="ct-fico" style="background:#8e8e99">' +
          '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M19.6 12c0 3.4-3.4 6.2-7.6 6.2-.8 0-1.6-.1-2.4-.3l-3.7 1.7 1.1-3.1C5.6 15.2 4.4 13.7 4.4 12c0-3.4 3.4-6.2 7.6-6.2s7.6 2.8 7.6 6.2z"/></svg>' +
        '</span><span class="ct-flabel">仅聊天的朋友</span></div>' +
        '<div class="ct-func" id="ctTags"><span class="ct-fico" style="background:#4c93dd">' +
          '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M11.4 4.4h6.2a2 2 0 0 1 2 2v6.2l-8.4 8.4a2 2 0 0 1-2.8 0L4 16.6a2 2 0 0 1 0-2.8z"/><circle cx="15.4" cy="8.6" r="1.3" fill="#fff" stroke="none"/></svg>' +
        '</span><span class="ct-flabel">标签</span></div>' +
        '<div class="ct-func" id="ctService"><span class="ct-fico" style="background:#4c93dd">' +
          '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="8.4"/><path d="M8.6 12.6l2.4 2.4 4.6-5"/></svg>' +
        '</span><span class="ct-flabel">服务号</span></div>' +
        '<div class="ct-func" id="ctWork"><span class="ct-fico" style="background:#35a87e">' +
          '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="9.4" r="3.4"/><path d="M5.6 19.4c0-3.2 2.9-5.4 6.4-5.4s6.4 2.2 6.4 5.4"/></svg>' +
        '</span><span class="ct-flabel">企业微信联系人</span></div>' +
        '<div class="ct-func" id="ctMyWork"><span class="ct-fico" style="background:#35a87e">' +
          '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="4.4" y="8.4" width="15.2" height="10.4" rx="2.2"/><path d="M9.4 8.4V6.6h5.2v1.8M12 11.6v3.6M10.2 13.4h3.6"/></svg>' +
        '</span><span class="ct-flabel">我的企业</span></div>' +
      '</div>';
    }

    // 好友按拼音首字母分组
    var col = null;
    try { col = new Intl.Collator('zh-Hans-CN', { usage: 'sort' }); } catch (e) { col = null; }
    var list = (S.friends || []).filter(function (f) {
      if (!kw) return true;
      return String(f.nickname || '').toLowerCase().indexOf(kw) >= 0 || String(f.username || '').toLowerCase().indexOf(kw) >= 0;
    }).slice();
    list.sort(function (a, b) {
      var an = a.nickname || '', bn = b.nickname || '';
      if (col) return col.compare(an, bn);
      return String(an).localeCompare(String(bn));
    });
    var groups = [], map = {};
    list.forEach(function (f) {
      var L = initialOf(f.nickname || f.username);
      if (!map[L]) { map[L] = []; groups.push(L); }
      map[L].push(f);
    });
    rows += groups.map(function (L) {
      // 分组字母不再插在列表中间（只有右侧 A-Z 索引）；data-letter 挂到该组第一行，方便跳转
      var head = '<div class="ct-head" data-letter="' + esc(L) + '" hidden></div>';
      var body = map[L].map(function (f, idx) {
        var face = f.avatar ? '<img src="' + esc(f.avatar) + '" alt="" loading="lazy" decoding="async">' : esc(initials(f.nickname));
        return '<div class="ct-row" data-friend="' + esc(f.id) + '"' + (idx === 0 ? ' data-letter-row="' + esc(L) + '"' : '') + '>' +
          '<div class="ct-avatar" data-uid="' + esc(f.id) + '">' + face + '</div>' +
          '<div class="ct-name">' + esc(f.nickname || f.username) + '</div>' +
        '</div>';
      }).join('');
      return head + body;
    }).join('') || '<div class="wx-empty">' + (kw ? '没有匹配的好友' : '还没有好友') + '</div>';
    box.innerHTML = rows;
    renderContactIndex(groups);
  }

  /* 右侧 A-Z 索引 */
  var CT_LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ#'.split('');
  function initialOf(name) {
    var s = String(name || '').trim();
    if (!s) return '#';
    var c = s[0];
    if (/[a-zA-Z]/.test(c)) return c.toUpperCase();
    if (!/[\u4e00-\u9fa5]/.test(c)) return '#';
    var bounds = [['A', '阿'], ['B', '八'], ['C', '擦'], ['D', '搭'], ['E', '蛾'], ['F', '发'], ['G', '噶'], ['H', '哈'],
      ['J', '击'], ['K', '喀'], ['L', '垃'], ['M', '妈'], ['N', '拿'], ['O', '哦'], ['P', '啪'], ['Q', '期'], ['R', '然'],
      ['S', '撒'], ['T', '塌'], ['W', '挖'], ['X', '昔'], ['Y', '压'], ['Z', '匝']];
    var col = null;
    try { col = new Intl.Collator('zh-Hans-CN', { usage: 'sort' }); } catch (e) { col = null; }
    if (!col) return '#';
    var letter = '#';
    for (var i = 0; i < bounds.length; i++) {
      if (col.compare(c, bounds[i][1]) >= 0) letter = bounds[i][0]; else break;
    }
    return letter;
  }

  function renderContactIndex(groups) {
    var box = $('ctIndex');
    if (!box) return;
    box.innerHTML = '<span class="ct-idx-search" id="ctIdxSearch" title="搜索">' +
        '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="6.4"/><path d="M15.8 15.8L20.5 20.5"/></svg>' +
      '</span>' +
      CT_LETTERS.map(function (L) {
      return '<span class="ct-idx' + (groups.indexOf(L) >= 0 ? ' is-on' : '') + '" data-l="' + L + '">' + L + '</span>';
    }).join('');

    if ($('ctIdxSearch')) {
      $('ctIdxSearch').addEventListener('click', function () {
        var box2 = $('ctSearch');
        if (!box2) return;
        box2.focus();
        try { box2.select(); } catch (e) { }
      });
    }
  }

  function jumpToLetter(L) {
    var head = document.querySelector('#contactList [data-letter-row="' + L + '"]') ||
      document.querySelector('#contactList [data-letter="' + L + '"]');
    var box = $('ctLetter');
    if (!box) return;
    box.textContent = L;
    box.hidden = false;
    clearTimeout(box.__t);
    box.__t = setTimeout(function () { box.hidden = true; }, 700);
    if (head) {
      var wrap = $('contactList');
      // 用位置差算，稳定（分组头现在不显示了，靠行上的锚点）
      var top = head.getBoundingClientRect().top - wrap.getBoundingClientRect().top + wrap.scrollTop;
      wrap.scrollTop = Math.max(0, top);
    } else {
      toast('没有 ' + L + ' 开头的联系人');
    }
  }

    /* ---------------------------------------------------------- 聊天 */
    /* 顶栏 / 输入栏是浮在消息上面的毛玻璃，量一下它们真实高度，
       消息区上下留出一样的空白，这样滚到顶/底不会钻到玻璃底下看不见 */
    function syncGlassHeights() {
      var cs = $('chatScreen');
      if (!cs) return;
      var nav = cs.querySelector('.wx-nav');
      var comp = cs.querySelector('.wx-composer');
      if (nav) cs.style.setProperty('--chat-nav-h', Math.round(nav.getBoundingClientRect().height) + 'px');
      if (comp) cs.style.setProperty('--composer-h', Math.round(comp.getBoundingClientRect().height) + 'px');
    }
    window.addEventListener('resize', function () { if (!$('chatScreen').hidden) syncGlassHeights(); });

    function openChat(chatId) {
    S.activeChat = chatId;
    var chat = S.chats.filter(function (c) { return c.id === chatId; })[0] || {};
      /* 群聊标题和微信一样带人数：群名(9)；单聊就是对方名字 */
      $('chatTitle').textContent = chat.type === 'group'
        ? (chat.title || '群聊') + '(' + (chat.memberCount || 0) + ')'
        : (chat.title || '聊天');
      $('chatScreen').hidden = false;
      syncGlassHeights();      // 毛玻璃顶栏/输入栏：量一下实际高度，消息区留出同样的上下留白
    var cached = S.messages[chatId];
    if (cached && cached.length) { renderMessages(); }          // 有同步下来的缓存先显示
    else $('messages').innerHTML = '<div class="wx-msg-time">正在加载…</div>';
    api('/chats/' + encodeURIComponent(chatId) + '/messages?limit=60').then(function (d) {
      S.messages[chatId] = d.messages || [];
      S.hasOlder = S.hasOlder || {};
      S.hasOlder[chatId] = !!d.hasMore;
      saveMsgCache();
      if (d.chat) {
        var idx = S.chats.findIndex(function (c) { return c.id === d.chat.id; });
        if (idx >= 0) S.chats[idx] = d.chat; else S.chats.unshift(d.chat);
        renderChats();
      }
      renderMessages();
      markRead(chatId);
    }).catch(function (e) { toast(e.message); });
  }

  /* 往上看更早的消息（网页版）：服务端支持 before 翻页，一次 60 条 */
  window.loadOlderWeb = function () {
    var chatId = S.activeChat;
    var list = S.messages[chatId] || [];
    if (!list.length) { return; }
    var first = list[0];
    var box = $('messages');
    var beforeH = box ? box.scrollHeight : 0;
    api('/chats/' + encodeURIComponent(chatId) + '/messages?limit=60&before=' + (first.seq || 0)).then(function (d) {
      var older = d.messages || [];
      S.hasOlder = S.hasOlder || {};
      S.hasOlder[chatId] = !!d.hasMore;
      if (!older.length) { renderMessages(); return; }
      S.messages[chatId] = older.concat(list);
      saveMsgCache();
      renderMessages();
      if (box) { box.scrollTop = box.scrollHeight - beforeH; }   // 保持原来的视觉位置
    }).catch(function (e) { toast(e.message); });
  };

 function closeChat() {
    S.activeChat = null;
    $('chatScreen').hidden = true;
    setEmojiOpen(false);
    setPlusOpen(false);
    setGiftOpen(false);
    loadChats();
  }

  /* 系统消息（通话记录）：微信是一行居中的小灰字，前面带个电话/摄像机小图标。
     后台换图标是 App 那边的事，网页版用内置的这套就够（两边长得一样）。 */
  var SYS_CALL_ICON = '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M6.6 2.4c.5 0 1 .3 1.2.8l1.5 3.3c.2.5.1 1.1-.3 1.5l-1.3 1.3c1 2 2.6 3.6 4.6 4.6l1.3-1.3c.4-.4 1-.5 1.5-.3l3.3 1.5c.5.2.8.7.8 1.2v3.2c0 .8-.6 1.5-1.4 1.6-.6.1-1.2.1-1.9.1C9.7 19.9 4.1 14.3 3.3 6.6c-.1-.7-.1-1.3 0-1.9.1-.8.8-1.4 1.6-1.4h1.7z"/></svg>';
  var SYS_VIDEO_ICON = '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="2.2" y="5.6" width="13.2" height="12.8" rx="3.4"/><path d="M16.9 10.4l3.9-2.6c.5-.3 1.1 0 1.1.6v7.2c0 .6-.6.9-1.1.6l-3.9-2.6z"/></svg>';
  /* 通话记录的文案：老记录写的是「通话结束 · 时长 0:15」，统一成微信那样「通话时长 00:15」 */
  function callRecordText(m) {
    var t = String(m.content || '');
    t = t.replace(/^视频通话结束\s*[·・]?\s*时长\s*/, '通话时长 ');
    t = t.replace(/^通话结束\s*[·・]?\s*时长\s*/, '通话时长 ');
    t = t.replace(/^视频通话时长\s*/, '通话时长 ');
    var mm = t.match(/^通话时长\s+(\d{1,2}):(\d{2})$/);
    if (mm) t = '通话时长 ' + ('0' + mm[1]).slice(-2) + ':' + mm[2];
    return t;
  }
  function systemLine(m) {
    var t = callRecordText(m);
    var isCall = /通话|已取消|未接听|对方无应答|对方已拒绝|对方忙线中|对方不在线/.test(t);
    var video = (m.call && String(m.call.media) === 'video') || String(m.content || '').indexOf('视频') >= 0;
    var icon = isCall ? '<span class="wx-sys-ico">' + (video ? SYS_VIDEO_ICON : SYS_CALL_ICON) + '</span>' : '';
    return '<div class="wx-msg-system">' + icon + '<span>' + esc(t) + '</span></div>';
  }

  function renderMessages() {
    var list = S.messages[S.activeChat] || [];
    var box = $('messages');
    var hidden = hiddenMsgIds(S.activeChat);
    if (!list.length) { box.innerHTML = '<div class="wx-msg-time">还没有消息，打个招呼吧</div>'; return; }
    // 只有本来就贴着底部时才自动滚到底，避免用户翻历史时被拽走
    var nearBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 140;
    var curChat = S.chats.filter(function (c) { return c.id === S.activeChat; })[0] || {};
    var isGroup = curChat.type === 'group';
    var html = '', lastDay = '';
    /* 上面还有更早的记录：顶部给一个入口（服务端支持 before 翻页） */
    if (S.hasOlder && S.hasOlder[S.activeChat]) {
      html += '<div class="wx-msg-time" style="cursor:pointer" onclick="loadOlderWeb()">查看更早的消息</div>';
    }
    list.forEach(function (m) {
      if (hidden.indexOf(m.id) >= 0) return;                 // 本地删掉的消息不再显示
      var day = new Date(m.createdAt).toDateString();
      if (day !== lastDay) {
        lastDay = day;
        html += '<div class="wx-msg-time"><span>' + esc(dividerTime(m.createdAt)) + '</span></div>';
      }
      var mine = m.senderId === S.me.id;
      /* 系统消息（通话记录这种）：和 App / 微信一样，居中一行小灰字，前面带电话图标 */
      if (m.kind === 'system') {
        /* 微信的通话记录是一条气泡：自己打出去的在右边（绿），对方打来的在左边（白）。
           from 是服务端新加的；老记录没有 from，还是退回「居中一行灰字」。 */
        var callFrom = (m.call && m.call.from) ? String(m.call.from) : '';
        if (callFrom) {
          var mineCall = callFrom === S.me.id;
          var cTxt = callRecordText(m);
          var cVideo = (m.call && String(m.call.media) === 'video') || String(m.content || '').indexOf('视频') >= 0;
          /* 头像：自己那边用我的头像，对方那边用会话里对方的头像 */
          var cFaceUrl = mineCall ? (S.me.avatar || '') : (curChat.avatar || '');
          var cFaceName = mineCall ? (S.me.nickname || '我') : (curChat.name || '');
          var cFace = cFaceUrl
            ? '<img src="' + esc(cFaceUrl) + '" alt="" loading="lazy" decoding="async">'
            : esc(initials(cFaceName));
          html += '<div class="wx-msg' + (mineCall ? ' is-me' : '') + '" data-id="' + esc(m.id) + '">' +
            '<div class="wx-msg-avatar"' + (mineCall ? '' : ' data-uid="' + esc(callFrom) + '"') + '>' + cFace + '</div>' +
            '<div class="wx-bubble wx-call-bubble">' +
              '<span class="wx-call-ico">' + (cVideo ? SYS_VIDEO_ICON : SYS_CALL_ICON) + '</span>' +
              '<span>' + esc(cTxt) + '</span>' +
            '</div></div>';
          return;
        }
        html += systemLine(m);
        return;
      }
      var face = mine ? (S.me.avatar ? '<img src="' + esc(S.me.avatar) + '" alt="" loading="lazy" decoding="async">' : esc(initials(S.me.nickname)))
        : (m.senderAvatar ? '<img src="' + esc(m.senderAvatar) + '" alt="" loading="lazy" decoding="async">' : esc(initials(m.senderName)));
      var body;
      if (m.kind === 'image') body = '<div class="wx-bubble"><img src="' + esc(m.content) + '" alt="图片" data-img="' + esc(m.content) + '" loading="lazy" decoding="async"></div>';
      else if (m.kind === 'audio') {
        /* 语音消息：能点开听（以前只显示一行「🎤 语音」，点了没反应） */
        var ao = null;
        try { ao = JSON.parse(m.content); } catch (e) { ao = null; }
        var asrc = (ao && ao.url) ? String(ao.url) : '';
        var asec = (ao && ao.seconds) ? Number(ao.seconds) : 0;
        body = '<div class="wx-bubble wx-voice" data-voice="' + esc(asrc) + '">' +
          '<span class="wx-voice-ico">🎤</span> 语音' + (asec ? ' ' + asec + '″' : '') + '</div>';
      }
      else if (m.kind === 'file') body = '<div class="wx-bubble">📄 文件</div>';
      else if (m.kind === 'gift') body = giftBubble(m.content);
      else if (m.kind === 'transfer') body = transferBubble(m.content, mine);
      else if (m.kind === 'redpacket') body = rpCard(m.content, mine);
      else if (m.kind === 'location') body = locationBubble(m.content);
      else body = '<div class="wx-bubble">' + linkify(m.content) + '</div>';
      // 群聊：名字放在气泡上方（参考图就是这样）
      if (isGroup && !mine) body = '<div class="wx-msg-body"><div class="wx-msg-sender">' + esc(m.senderName || '') + '</div>' + body + '</div>';
      var faceUid = mine ? ((S.me && S.me.id) || '') : (m.senderId || '');
      html += '<div class="wx-msg' + (mine ? ' is-me' : '') + '" data-id="' + esc(m.id) + '">' +
        '<div class="wx-msg-avatar"' + (faceUid ? ' data-uid="' + esc(faceUid) + '"' : '') + '>' + face + '</div>' +
        body + '</div>';
    });
    box.innerHTML = html;
    if (nearBottom) box.scrollTop = box.scrollHeight;
  }

  /* ---------------- 滚动性能：不要每来一条消息就重画整个列表 ---------------- */
  var reloadTimer = null, scrolling = false, scrollEndTimer = null;
  function markScrolling() {
    scrolling = true;
    /* 滑动期间给 html 加个类：CSS 里趁机关掉毛玻璃（iOS 滚动 + backdrop-blur 最卡） */
    try { document.documentElement.classList.add('is-scrolling'); } catch (e) { }
    clearTimeout(scrollEndTimer);
    scrollEndTimer = setTimeout(function () {
      scrolling = false;
      try { document.documentElement.classList.remove('is-scrolling'); } catch (e) { }
    }, 280);
  }
  function scheduleChatReload() {
    if (reloadTimer) return;
    reloadTimer = setTimeout(function () {
      reloadTimer = null;
      if (scrolling) { scheduleChatReload(); return; }   // 正在滑动就先别重画
      /* 聊天窗口开着的时候，会话列表被盖住了，重画纯属浪费（每次都要重建 60 多行 DOM，
         手机上就是「一发消息就卡一下」）。先记一笔，等退出聊天窗口再刷。 */
      if (!$('chatScreen').hidden) return;   // 退出聊天窗口时 closeChat() 会自己 loadChats()
      loadChats();
    }, 300);
  }

  function markRead(chatId) {
    if (socket && socket.readyState === 1) {
      socket.send(JSON.stringify({ type: 'read', chatId: chatId }));
    } else {
      api('/chats/' + encodeURIComponent(chatId) + '/read', { method: 'POST' }).catch(function () { });
    }
    var c = S.chats.filter(function (x) { return x.id === chatId; })[0];
    if (c) { c.unread = 0; renderChats(); }
  }

  function sendMessage() {
    var input = $('msgInput');
    var text = input.value.trim();
    if (!text || !S.activeChat) return;
    input.value = '';
    updateSendBtn();
    var clientId = 'c' + Date.now() + Math.random().toString(16).slice(2, 6);
    var list = S.messages[S.activeChat] = S.messages[S.activeChat] || [];
    list.push({ id: clientId, senderId: S.me.id, senderName: S.me.nickname, senderAvatar: S.me.avatar, kind: 'text', content: text, createdAt: new Date().toISOString(), pending: true });
    renderMessages();
    var payload = { type: 'send', chatId: S.activeChat, kind: 'text', content: text, clientId: clientId };
    var sent = false;
    if (socket && socket.readyState === 1) { try { socket.send(JSON.stringify(payload)); sent = true; } catch (e) { sent = false; } }
    if (!sent) {
      api('/chats/' + encodeURIComponent(S.activeChat) + '/messages', {
        method: 'POST', body: JSON.stringify({ kind: 'text', content: text, clientId: clientId })
      }).catch(function (e) { toast(e.message); });
    }
    loadChats();
  }

  /* 发送按钮已按需求删除：+ 号常显，回车发送 */
  function updateSendBtn() {
    if ($('btnPlus')) $('btnPlus').hidden = false;
    // 表情面板里的发送键：输入框有内容才是微信绿，空的时候浅灰
    var send = $('emojiSend');
    if (send) send.classList.toggle('is-on', !!$('msgInput').value.trim());
    // 左边那个删除键（⌫）跟着一起：没内容浅灰，有内容变亮
    var del = $('emojiDel');
    if (del) del.classList.toggle('is-on', !!$('msgInput').value.trim());
  }

  /* ---------------------------------------------------------- 表情面板（和微信表情包一致） */
  /* 前两页是微信经典小黄脸的顺序，后面两页是常用的手势 / 动物 / 食物 */
  var EMOJI_ALL = [
    '😄', '😖', '😍', '😳', '😎', '😭', '😚', '🤐',
    '😴', '😢', '😅', '😡', '😛', '😁', '😲', '😔',
    '😎', '😰', '😫', '🤢', '🤭', '😊', '🙄', '😤',
    '🤤', '😪', '😱', '😅', '😃', '🫡', '💪', '🤬',

    '🤔', '🤫', '😵', '😩', '😞', '💀', '🔨', '👋',
    '😅', '🤧', '👏', '😳', '😏', '😤', '😤', '🥱',
    '😒', '🥺', '😢', '😏', '😘', '😨', '🥺', '🔪',
    '🍉', '🍺', '🏀', '🏓', '☕', '🍚', '🐷', '🌹',

    '🥀', '😘', '❤️', '💔', '🎂', '⚡', '💣', '🗡️',
    '⚽', '🐞', '💩', '🌙', '☀️', '🎁', '🤗', '👍',
    '👎', '🤝', '✌️', '🙏', '😉', '👊', '👌', '🕺',
    '🥶', '😤', '🌀', '🙇', '🔄', '🏃', '👋', '🤩',

    '👍', '👏', '🙏', '✌️', '❤️', '🌹', '🎁', '🎉',
    '🔥', '⭐', '🌈', '🎵', '☕', '🎂', '🧧', '☀️',
    '🌙', '☁️', '🌧️', '❄️', '🐱', '🐶', '🐼', '🐰',
    '🐷', '🐵', '🐯', '🐟', '🍎', '🍓', '🍉', '🍺'
  ];
  var EMOJI_PER_PAGE = 32;
  var emojiBuilt = false;

  function buildEmojiPanel() {
    if (emojiBuilt) return;
    emojiBuilt = true;
    var pages = '', dots = '', n = Math.ceil(EMOJI_ALL.length / EMOJI_PER_PAGE);
    for (var p = 0; p < n; p++) {
      var cells = '';
      for (var i = p * EMOJI_PER_PAGE; i < (p + 1) * EMOJI_PER_PAGE && i < EMOJI_ALL.length; i++) {
        cells += '<button type="button" class="wx-emoji-cell" data-e="' + EMOJI_ALL[i] + '" aria-label="表情">' + EMOJI_ALL[i] + '</button>';
      }
      pages += '<div class="wx-emoji-page">' + cells + '</div>';
      dots += '<span class="wx-emoji-dot' + (p === 0 ? ' is-on' : '') + '"></span>';
    }
    $('emojiPages').innerHTML = pages;
    $('emojiDots').innerHTML = dots;
  }

  function paintEmojiDots() {
    var box = $('emojiPages');
    var i = Math.round(box.scrollLeft / Math.max(1, box.clientWidth));
    var ds = $('emojiDots').children;
    for (var k = 0; k < ds.length; k++) {
      if (k === i) ds[k].classList.add('is-on'); else ds[k].classList.remove('is-on');
    }
  }

  function insertEmoji(ch) {
    var input = $('msgInput');
    var s = input.selectionStart, e = input.selectionEnd;
    if (typeof s === 'number' && typeof e === 'number' && document.activeElement === input) {
      input.value = input.value.slice(0, s) + ch + input.value.slice(e);
      var pos = s + ch.length;
      try { input.setSelectionRange(pos, pos); } catch (err) { }
    } else {
      input.value += ch;      // 光标默认停在末尾，和微信一致
    }
    updateSendBtn();
  }

  function emojiBackspace() {
    var input = $('msgInput');
    var arr = Array.from(input.value);
    arr.pop();
    input.value = arr.join('');
    updateSendBtn();
  }

  function setEmojiOpen(open) {
    var panel = $('emojiPanel');
    if (!panel) return;
    if (open) buildEmojiPanel();
    panel.hidden = !open;
    if (open) {
      setPlusOpen(false);
      try { $('msgInput').blur(); } catch (e) { }   // 收起系统键盘，面板顶上来
      updateSendBtn();
    }
    updatePanelSpace();
  }

  function toggleEmojiPanel() { setEmojiOpen(!!$('emojiPanel').hidden); }

  /* 表情面板 / ＋ 面板 谁开着，消息区就按谁的高度留白，最后一条不会被盖住 */
  function updatePanelSpace() {
    var h = 0;
    ['emojiPanel', 'plusPanel', 'giftPanel'].forEach(function (id) {
      var el = $(id);
      if (el && !el.hidden) h = Math.max(h, Math.round(el.getBoundingClientRect().height));
    });
    document.documentElement.style.setProperty('--ep', h ? (h + 8) + 'px' : '0px');
    var box = $('messages');
    if (box) box.scrollTop = box.scrollHeight;
  }

  /* ---------------------------------------------------------- ＋ 面板（内容由后台控制） */
  /* 兜底配置：和后台默认值一致，第一页就是参考图那 8 个 */
  var PLUS_FALLBACK = [
    { id: 'p01', label: '照片', icon: 'photo', action: 'photo', enabled: true },
    { id: 'p02', label: '拍摄', icon: 'camera', action: 'camera', enabled: true },
    { id: 'p03', label: '视频通话', icon: 'video', action: 'videocall', enabled: true },
    { id: 'p04', label: '位置', icon: 'location', action: 'location', enabled: true },
    { id: 'p05', label: '红包', icon: 'redpacket', action: 'redpacket', enabled: true },
    { id: 'p06', label: '礼物', icon: 'gift', action: 'gift', enabled: true },
    { id: 'p07', label: '转账', icon: 'transfer', action: 'transfer', enabled: true },
    { id: 'p08', label: '语音输入', icon: 'voice', action: 'voice', enabled: true },
    { id: 'p09', label: '收藏', icon: 'favorite', action: 'favorite', enabled: true },
    { id: 'p10', label: '名片', icon: 'card', action: 'card', enabled: true },
    { id: 'p11', label: '文件', icon: 'file', action: 'file', enabled: true },
    { id: 'p12', label: '音乐', icon: 'music', action: 'music', enabled: true },
    { id: 'p13', label: '卡券', icon: 'coupon', action: 'coupon', enabled: true }
  ];
  var PLUS_ICON_SVG = {
    photo: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3.2" y="4.8" width="17.6" height="14.4" rx="2.4"/><circle cx="8.6" cy="9.8" r="1.7"/><path d="M3.6 16.6l4.6-4.2 3.5 3.1 3-2.7 5.7 5"/></svg>',
    camera: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3.2 8.6a2.2 2.2 0 0 1 2.2-2.2h2.1l1.4-2.1h6.2l1.4 2.1h2.1a2.2 2.2 0 0 1 2.2 2.2v8.4a2.2 2.2 0 0 1-2.2 2.2H5.4a2.2 2.2 0 0 1-2.2-2.2z"/><circle cx="12" cy="12.6" r="3.6"/></svg>',
    video: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="2.8" y="6" width="12.6" height="12" rx="2.6"/><path d="M15.4 12.2l5.8-3.6v6.8l-5.8-3.2z"/></svg>',
    location: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 21.2s6.6-5.9 6.6-10.4A6.6 6.6 0 0 0 5.4 10.8c0 4.5 6.6 10.4 6.6 10.4z"/><circle cx="12" cy="10.6" r="2.5"/></svg>',
    redpacket: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="7.6" width="16" height="11.6" rx="2.2"/><path d="M4 7.6h16L12 13z"/><path d="M11 15.6h2M12 15.6v1.6"/></svg>',
    gift: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3.6" y="9.6" width="16.8" height="10.8" rx="2.2"/><path d="M3.6 13.6h16.8M12 9.6v10.8"/><path d="M9.4 9.6c-1.9 0-2.9-1-2.9-2.2S7.6 5 9.1 5c1.9 0 2.9 2 2.9 4.6.1-2.6 1.1-4.6 3-4.6 1.5 0 2.6.6 2.6 1.8s-1 2.2-2.9 2.2z"/></svg>',
    transfer: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3.6 9.6h13.2l-3.2-3.4M20.4 14.4H7.2l3.2 3.4"/></svg>',
    voice: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="9.2" y="3.4" width="5.6" height="10.4" rx="2.8"/><path d="M5.8 11.4a6.2 6.2 0 0 0 12.4 0M12 17.8v2.8"/></svg>',
    favorite: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4.4l2.4 4.9 5.4.8-3.9 3.8.9 5.3-4.8-2.5-4.8 2.5.9-5.3-3.9-3.8 5.4-.8z"/></svg>',
    card: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3.4" y="4.6" width="17.2" height="14.8" rx="2.4"/><circle cx="9.2" cy="10.6" r="2"/><path d="M6.2 16.4c.5-1.7 1.7-2.6 3-2.6s2.5.9 3 2.6M14.6 10h3.6M14.6 13.4h3.6"/></svg>',
    file: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M6.4 3.6h7.2l4.4 4.4v12.4H6.4z"/><path d="M13.4 3.8v4.4h4.4"/></svg>',
    music: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M9.2 17.4V6.2l9.2-1.8v11"/><circle cx="6.9" cy="17.8" r="2.3"/><circle cx="16.1" cy="15.6" r="2.3"/></svg>',
    coupon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3.6 7.6h16.8v3a2.4 2.4 0 0 0 0 4.8v3H3.6v-3a2.4 2.4 0 0 0 0-4.8z"/><path d="M9.6 8.4v9.2"/></svg>',
    chain: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M10.2 13.8a3.6 3.6 0 0 0 5.1 0l3-3a3.6 3.6 0 0 0-5.1-5.1l-1 1"/><path d="M13.8 10.2a3.6 3.6 0 0 0-5.1 0l-3 3a3.6 3.6 0 0 0 5.1 5.1l1-1"/></svg>',
    vote: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M5.4 19.6V10M12 19.6V4.8M18.6 19.6v-6.2"/></svg>',
    screen: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="12" rx="2.2"/><path d="M9 20h6"/></svg>',
    star: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4.4l2.4 4.9 5.4.8-3.9 3.8.9 5.3-4.8-2.5-4.8 2.5.9-5.3-3.9-3.8 5.4-.8z"/></svg>',
    heart: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20s-7.2-4.4-7.2-9.4A4.2 4.2 0 0 1 12 7.8a4.2 4.2 0 0 1 7.2 2.8C19.2 15.6 12 20 12 20z"/></svg>',
    link: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M10.6 13.4a4 4 0 0 0 5.6 0l2.4-2.4a4 4 0 0 0-5.6-5.6"/><path d="M13.4 10.6a4 4 0 0 0-5.6 0l-2.4 2.4a4 4 0 0 0 5.6 5.6"/></svg>',
    none: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><circle cx="12" cy="12" r="8.4"/><path d="M8.6 12h6.8"/></svg>'
  };
  var plusBuilt = false;

  function plusItems() {
    var list = (S.plusItems || PLUS_FALLBACK).filter(function (x) { return x && x.enabled !== false; });
    return list.length ? list : PLUS_FALLBACK;
  }

  function loadPlusPanel() {
    return api('/plus-panel').then(function (d) {
      if (d && d.items && d.items.length) {
        S.plusItems = d.items;
        if (!$('plusPanel').hidden) { plusBuilt = false; buildPlusPanel(); }
      }
    }).catch(function () { });
  }

  function buildPlusPanel() {
    var pages = '', dots = '', list = plusItems(), per = 8;
    var n = Math.max(1, Math.ceil(list.length / per));
    for (var p = 0; p < n; p++) {
      var cells = '';
      for (var i = p * per; i < (p + 1) * per && i < list.length; i++) {
        var it = list[i];
        cells += '<button type="button" class="wx-plus-cell" data-act="' + esc(it.action || 'none') + '" data-label="' + esc(it.label || '') + '">' +
          (PLUS_ICON_SVG[it.icon] || PLUS_ICON_SVG.star) + '<span>' + esc(it.label || '') + '</span></button>';
      }
      pages += '<div class="wx-plus-page">' + cells + '</div>';
      dots += '<span class="wx-emoji-dot' + (p === 0 ? ' is-on' : '') + '"></span>';
    }
    $('plusPages').innerHTML = pages;
    $('plusDots').innerHTML = n > 1 ? dots : '';
    plusBuilt = true;
  }

  function paintPlusDots() {
    var box = $('plusPages');
    var i = Math.round(box.scrollLeft / Math.max(1, box.clientWidth));
    var ds = $('plusDots').children;
    for (var k = 0; k < ds.length; k++) {
      if (k === i) ds[k].classList.add('is-on'); else ds[k].classList.remove('is-on');
    }
  }

  function setPlusOpen(open) {
    var panel = $('plusPanel');
    if (!panel) return;
    if (open && !plusBuilt) buildPlusPanel();
    panel.hidden = !open;
    if (open) setEmojiOpen(false);
    updatePanelSpace();
    if (open) { try { $('msgInput').blur(); } catch (e) { } }
  }

  function togglePlusPanel() { setPlusOpen(!!$('plusPanel').hidden); }

  /* ＋ 面板点每一项做什么 */
  function plusTap(action, label) {
    /* 「照片」：App 里直接进相册；网页版退回 input（写具体格式，少一层菜单） */
    if (action === 'photo') {
      pickImages('plusFile', 1, function (files) { if (files[0]) sendPickedFile(files[0]); });
      return;
    }
    if (action === 'camera') { openPlusFile('image/*', true); return; }
    if (action === 'file') { openPlusFile('', false); return; }
    if (action === 'location') { openLocationPicker(); return; }
    if (action === 'redpacket') { setPlusOpen(false); openRedPacketSend(); return; }
    if (action === 'gift') { openGiftPanel(); return; }
    if (action === 'transfer') { openTransfer(); return; }
    if (action === 'videocall') { startCall('video'); return; }
    if (action === 'voice') { toast('按住说话：请在电脑版或聊天页右上角使用'); return; }
    if (action === 'favorite') { toast('收藏夹还是空的'); return; }
    if (action === 'card') { toast('名片：去「通讯录」点头像即可发送'); return; }
    toast('「' + (label || '这个功能') + '」暂未开放，可在后台关掉');
  }

  /* ---------------------------------------------------------- 表情包（我 → 表情）
     本地表情包走后台「表情包」页；第三方图源默认关闭，后台填了 key 才出现搜索框 */
  function loadStickers() {
    return api('/stickers').then(function (d) {
      S.stickerPacks = d.packs || [];
      S.stickerTp = d.thirdParty || { provider: 'off', enabled: false };
      if (!$('stickerScreen').hidden) renderStickers();
    }).catch(function () { });
  }

  function openStickers() {
    $('stickerScreen').hidden = false;
    S.stickerTab = 0;
    $('stkSearchRow').hidden = !(S.stickerTp && S.stickerTp.enabled);
    $('stkSearch').value = '';
    renderStickers();
  }

  function renderStickers(list, searching) {
    var packs = S.stickerPacks || [];
    var tabs = '<button class="stk-tab' + (!searching && S.stickerTab < 0 ? ' is-on' : '') + '" data-pack="-1">全部</button>' +
      packs.map(function (p, i) {
        return '<button class="stk-tab' + (!searching && S.stickerTab === i ? ' is-on' : '') + '" data-pack="' + i + '"><span class="ic">' + esc(p.icon || '🙂') + '</span>' + esc(p.name) + '</button>';
      }).join('');
    $('stkPacks').innerHTML = searching ? '' : tabs;
    var cells = '';
    if (searching) {
      cells = (list || []).map(function (x) {
        return '<button class="stk-cell" data-img="' + esc(x.url) + '" title="' + esc(x.title || '') + '"><img src="' + esc(x.url) + '" alt="" loading="lazy"></button>';
      }).join('');
    } else {
      var pick = (S.stickerTab >= 0 && packs[S.stickerTab]) ? packs[S.stickerTab].stickers : null;
      var all = [];
      if (pick) all = pick;
      else packs.forEach(function (p) { all = all.concat(p.stickers || []); });
      cells = all.map(function (s) {
        return /^https?:\/\//i.test(s)
          ? '<button class="stk-cell" data-img="' + esc(s) + '"><img src="' + esc(s) + '" alt="" loading="lazy"></button>'
          : '<button class="stk-cell" data-txt="' + esc(s) + '">' + esc(s) + '</button>';
      }).join('');
    }
    $('stkGrid').innerHTML = cells;
    $('stkEmpty').hidden = !!cells;
  }

  function searchStickers() {
    var q = $('stkSearch').value.trim();
    if (!q) { renderStickers(); return; }
    $('stkGrid').innerHTML = '';
    toast('搜索中…');
    api('/stickers/search?q=' + encodeURIComponent(q)).then(function (d) {
      if (d.error) { toast(d.error); renderStickers(); return; }
      renderStickers(d.items || [], true);
      if (!(d.items || []).length) toast('没搜到，换个词试试');
    }).catch(function (e) { toast(e.message); renderStickers(); });
  }

  /* 发出去：表情字符当文字消息，图片当图片消息（没在聊天里就先挑一个会话） */
  function sendSticker(txt, img) {
    if (S.activeChat) { pushSticker(S.activeChat, txt, img); return; }
    var chats = (S.chats || []).slice(0, 6);
    if (!chats.length) { toast('还没有聊天，先去消息页找个人聊'); return; }
    sheet(chats.map(function (c) {
      return { label: '发给 ' + c.title, run: function () { pushSticker(c.id, txt, img); } };
    }));
  }

  function pushSticker(chatId, txt, img) {
    var kind = img ? 'image' : 'text';
    var content = img || txt;
    if (!chatId || !content) return;
    var clientId = 'c' + Date.now() + Math.random().toString(16).slice(2, 6);
    var payload = { type: 'send', chatId: chatId, kind: kind, content: content, clientId: clientId };
    var sent = false;
    if (socket && socket.readyState === 1) { try { socket.send(JSON.stringify(payload)); sent = true; } catch (e) { sent = false; } }
    if (!sent) {
      api('/chats/' + encodeURIComponent(chatId) + '/messages', { method: 'POST', body: JSON.stringify({ kind: kind, content: content, clientId: clientId }) })
        .catch(function (e) { toast(e.message); return null; });
    }
    var c = (S.chats || []).filter(function (x) { return x.id === chatId; })[0] || {};
    toast('表情已发给「' + (c.title || '好友') + '」');
    scheduleChatReload();
  }

  /* ---------------------------------------------------------- 礼物面板（礼物都在后台「礼物管理」里） */
  var GIFT_FALLBACK = [
    { id: 'g01', name: '玫瑰', icon: '🌹', price: 1, category: '浪漫' },
    { id: 'g02', name: '爱心', icon: '❤️', price: 2, category: '浪漫' },
    { id: 'g03', name: '花束', icon: '💐', price: 5, category: '浪漫' },
    { id: 'g04', name: '巧克力', icon: '🍫', price: 3, category: '浪漫' },
    { id: 'g05', name: '蛋糕', icon: '🎂', price: 8, category: '浪漫' },
    { id: 'g06', name: '钻戒', icon: '💍', price: 66, category: '浪漫' },
    { id: 'g07', name: '礼物盒', icon: '🎁', price: 5, category: '通用' },
    { id: 'g08', name: '气球', icon: '🎈', price: 1, category: '通用' },
    { id: 'g09', name: '星星', icon: '⭐', price: 2, category: '通用' },
    { id: 'g10', name: '点赞', icon: '👍', price: 1, category: '通用' },
    { id: 'g11', name: '啤酒', icon: '🍺', price: 3, category: '通用' },
    { id: 'g12', name: '皇冠', icon: '👑', price: 20, category: '豪华' },
    { id: 'g13', name: '烟花', icon: '🎆', price: 30, category: '豪华' },
    { id: 'g14', name: '火箭', icon: '🚀', price: 52, category: '豪华' },
    { id: 'g15', name: '跑车', icon: '🏎️', price: 88, category: '豪华' },
    { id: 'g16', name: '城堡', icon: '🏰', price: 199, category: '豪华' }
  ];
  var giftBuilt = false;

  function giftList() {
    var list = S.gifts || GIFT_FALLBACK;
    return list.length ? list : GIFT_FALLBACK;
  }

  function loadGifts() {
    return api('/gifts').then(function (d) {
      if (d && d.gifts && d.gifts.length) {
        S.gifts = d.gifts;
        if (!$('giftPanel').hidden) { giftBuilt = false; buildGiftPanel(); }
      }
    }).catch(function () { });
  }

  function buildGiftPanel() {
    var pages = '', dots = '', list = giftList(), per = 8;
    var n = Math.max(1, Math.ceil(list.length / per));
    for (var p = 0; p < n; p++) {
      var cells = '';
      for (var i = p * per; i < (p + 1) * per && i < list.length; i++) {
        var g = list[i];
        cells += '<button type="button" class="wx-gift-cell" data-g="' + esc(JSON.stringify(g)) + '">' +
          '<span class="gi">' + esc(g.icon || '🎁') + '</span>' +
          '<span class="gn">' + esc(g.name || '礼物') + '</span>' +
          '<span class="gp">' + esc(g.price || 0) + ' 金币</span>' +
        '</button>';
      }
      pages += '<div class="wx-gift-page">' + cells + '</div>';
      dots += '<span class="wx-emoji-dot' + (p === 0 ? ' is-on' : '') + '"></span>';
    }
    $('giftPages').innerHTML = pages;
    $('giftDots').innerHTML = n > 1 ? dots : '';
    giftBuilt = true;
  }

  function paintGiftDots() {
    var box = $('giftPages');
    var i = Math.round(box.scrollLeft / Math.max(1, box.clientWidth));
    var ds = $('giftDots').children;
    for (var k = 0; k < ds.length; k++) {
      if (k === i) ds[k].classList.add('is-on'); else ds[k].classList.remove('is-on');
    }
  }

  function setGiftOpen(open) {
    var panel = $('giftPanel');
    if (!panel) return;
    if (open && !giftBuilt) buildGiftPanel();
    panel.hidden = !open;
    if (open) {
      $('emojiPanel').hidden = true;
      $('plusPanel').hidden = true;
      try { $('msgInput').blur(); } catch (e) { }
    }
    updatePanelSpace();
  }

  function openGiftPanel() { setGiftOpen(true); }

  function sendGift(g) {
    if (!S.activeChat || !g) return;
    var cid = sendUploaded('gift', JSON.stringify({ id: g.id || '', name: g.name || '礼物', icon: g.icon || '🎁', price: Number(g.price) || 0 }));
    if (cid) giftLocalIds[cid] = Date.now();       // 自己送的那条：本地先放特效，收到回执就不再放一次
    playGiftFlood({ icon: g.icon, name: g.name, price: g.price }, '我');
    toast('已送出 ' + (g.icon || '') + ' ' + (g.name || '礼物'));
    setGiftOpen(false);
  }

  /* ---------------------------------------------------------- 礼物刷屏特效 */
  var floodQueue = [], floodBusy = false, floodTimer = null;
  var floodCombo = { key: '', n: 0, at: 0 };
  var giftLocalIds = {};

  function playGiftFlood(g, fromName) {
    if (!g) return;
    floodQueue.push({ g: g, from: fromName || '' });
    if (floodQueue.length > 6) floodQueue.splice(0, floodQueue.length - 6);
    if (!floodBusy) nextGiftFlood();
  }

  function nextGiftFlood() {
    var item = floodQueue.shift();
    if (!item) { floodBusy = false; return; }
    floodBusy = true;
    var g = item.g;
    // 同一个人连送同一个礼物 → 连击数往上翻，和微信那种连击一个意思
    var key = item.from + '|' + (g.name || '');
    var t = Date.now();
    if (floodCombo.key === key && t - floodCombo.at < 4000) floodCombo.n += 1;
    else { floodCombo.key = key; floodCombo.n = 1; }
    floodCombo.at = t;

    var sparks = '', dirs = [[-120, -60], [-70, -110], [0, -130], [74, -108], [122, -58], [-96, 30], [98, 34], [-40, -140], [46, -142], [140, 12]];
    for (var i = 0; i < dirs.length; i++) {
      sparks += '<i style="--dx:' + dirs[i][0] + 'px; --dy:' + dirs[i][1] + 'px; --rot:' + (i % 2 ? -60 : 60) + 'deg; --d:' + (0.08 * i).toFixed(2) + 's">' + (i % 3 === 0 ? '✨' : (i % 3 === 1 ? '⭐' : '💫')) + '</i>';
    }
    var kind = giftFloodKind(g);
    $('giftFloodInner').innerHTML =
      giftFloodFx(kind) +
      '<div class="gf-light"></div><div class="gf-ring"></div>' +
      '<div class="gf-emoji' + (kind ? ' is-' + kind : '') + '">' + esc(g.icon || '🎁') + '</div>' +
      '<div class="gf-sparks">' + sparks + '</div>' +
      '<div class="gf-who">' + (item.from ? ('<b>' + esc(item.from) + '</b> 送出') : '收到礼物') + '</div>' +
      '<div class="gf-name">' + esc(g.name || '礼物') + '</div>' +
      '<div class="gf-price">' + esc(Number(g.price) || 0) + ' 金币</div>' +
      (floodCombo.n > 1 ? '<div class="gf-combo">× ' + floodCombo.n + '</div>' : '');

    var box = $('giftFlood');
    box.className = 'wx-flood' + (kind ? ' is-' + kind : '');
    box.hidden = false;
    clearTimeout(floodTimer);
    var hold = floodCombo.n > 1 ? 1500
      : (kind === 'firework' ? 5200 : (kind === 'plane' ? 2900 : (kind === 'car' || kind === 'rocket' ? 2600 : 2300)));
    floodTimer = setTimeout(closeGiftFlood, hold);
  }

  function closeGiftFlood() {
    var box = $('giftFlood');
    if (!box || box.hidden) { floodBusy = false; nextGiftFlood(); return; }
    clearTimeout(floodTimer);
    box.classList.add('is-out');
    floodTimer = setTimeout(function () {
      box.hidden = true;
      box.classList.remove('is-out');
      floodBusy = false;
      nextGiftFlood();
    }, 240);
  }

  function giftBubble(content) {
    var g = giftInfoOf(content);
    return '<div class="wx-bubble is-gift"><span class="gb-ico">' + esc(g.icon || '🎁') + '</span>' +
      '<span class="gb-box"><span class="gb-name">' + esc(g.name || '礼物') + '</span>' +
      '<span class="gb-price">' + esc(Number(g.price) || 0) + ' 金币</span></span></div>';
  }

  /* ---------------- 消息长按菜单（撤回 / 复制 / 转发 / 收藏 / 删除） ---------------- */
  var msgMenuJustOpened = false;
  var lpTimer = null, lpStart = null;

  function msgById(id) {
    var list = S.messages[S.activeChat] || [];
    for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i];
    return null;
  }
  function hiddenKey(chatId) { return 'wx-msg-hidden-' + chatId; }
  function hiddenMsgIds(chatId) {
    try { return JSON.parse(localStorage.getItem(hiddenKey(chatId)) || '[]') || []; } catch (e) { return []; }
  }
  function hideMessageLocally(chatId, id) {
    var ids = hiddenMsgIds(chatId);
    if (ids.indexOf(id) < 0) ids.push(id);
    try { localStorage.setItem(hiddenKey(chatId), JSON.stringify(ids.slice(-500))); } catch (e) { }
  }
  /* 文本朗读（网页版用浏览器自带的语音）：文字消息、通话记录都能念 */
  function speakableText(m) {
    if (!m) return '';
    if (m.kind === 'system') {
      var t = callRecordText(m);
      return /通话|已取消|未接听|无应答|已拒绝|忙线|不在线/.test(t) ? t : '';
    }
    if (m.kind === 'text' || m.kind === 'link') return String(m.content || '');
    return '';
  }
  function speakText(text) {
    var t = String(text || '').trim();
    if (!t) return;
    if (!('speechSynthesis' in window)) { toast('这个浏览器不支持朗读'); return; }
    try {
      window.speechSynthesis.cancel();
      var u = new SpeechSynthesisUtterance(t);
      u.lang = 'zh-CN';
      u.rate = 0.95;
      var vs = window.speechSynthesis.getVoices() || [];
      for (var i = 0; i < vs.length; i++) {
        if (/^zh|Chinese/i.test(vs[i].lang || '')) { u.voice = vs[i]; break; }
      }
      window.speechSynthesis.speak(u);
      toast('正在朗读…');
    } catch (e) { toast('朗读失败'); }
  }

  function copyPlainText(text) {
    var t = String(text || '');
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(t).then(function () { toast('已复制'); }, function () { toast('复制失败，长按文字自己复制吧'); });
      return;
    }
    var ta = document.createElement('textarea');
    ta.value = t;
    ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); toast('已复制'); } catch (e) { toast('复制失败'); }
    document.body.removeChild(ta);
  }
  function recallMsg(m) {
    api('/messages/' + encodeURIComponent(m.id) + '/recall', { method: 'POST', body: JSON.stringify({ chatId: S.activeChat }) })
      .then(function () {
        m.recalled = true;
        renderMessages();
        toast('已撤回');
      })
      .catch(function (e) { toast(e.message || '撤回失败'); });
  }
  function forwardMsg(m) {
    var chats = (S.chats || []).slice(0, 12);
    if (!chats.length) { toast('没有可以转发的会话'); return; }
    var label = m.kind === 'image' ? '[图片]' : (m.kind === 'transfer' ? '[转账]' : String(m.content || '').slice(0, 14));
    sheet(chats.map(function (c) {
      return {
        label: '发给 ' + (c.title || '会话') + '（' + label + '）',
        run: function () {
          var kind = m.kind === 'image' ? 'image' : 'text';
          var content = m.kind === 'transfer'
            ? ('💰 转账 ¥' + (transferInfoOf(m.content).amount || 0).toFixed(2))
            : m.content;
          sendToChatId(c.id, kind, content);
        }
      };
    }));
  }
  function sendToChatId(chatId, kind, content) {
    var payload = { type: 'send', chatId: chatId, kind: kind, content: content, clientId: 'c_' + Date.now() };
    var sent = false;
    if (socket && socket.readyState === 1) { try { socket.send(JSON.stringify(payload)); sent = true; } catch (e) { sent = false; } }
    if (!sent) {
      api('/chats/' + encodeURIComponent(chatId) + '/messages', { method: 'POST', body: JSON.stringify(payload) })
        .then(function () { toast('已转发'); })
        .catch(function (e) { toast(e.message || '转发失败'); });
      return;
    }
    toast('已转发');
  }
  function favMsg(m) {
    var chat = S.chats.filter(function (c) { return c.id === S.activeChat; })[0] || {};
    var kind = m.kind === 'image' ? 'image' : (m.kind === 'transfer' ? 'transfer' : 'text');
    api('/favorites', {
      method: 'POST',
      body: JSON.stringify({ kind: kind, content: m.content, title: chat.title || '', from: m.senderName || '' })
    }).then(function (d) {
      toast('已收藏（共 ' + (d.count || 1) + ' 条）');
    }).catch(function (e) { toast(e.message || '收藏失败'); });
  }
  function openMsgMenu(id) {
    var m = msgById(id);
    if (!m) return;
    msgMenuJustOpened = true;
    var mine = m.senderId === S.me.id;
    var items = [];
    if (!m.recalled && m.kind === 'text') items.push({ label: '复制', run: function () { copyPlainText(m.content); } });
    /* 朗读（和 App 那边一样）：能念的文字消息/通话记录都放这一项 */
    var speakTxt = speakableText(m);
    if (speakTxt) items.push({ label: '朗读', run: function () { speakText(speakTxt); } });
    if (!m.recalled) items.push({ label: '转发', run: function () { forwardMsg(m); } });
    if (!m.recalled) items.push({ label: '收藏', run: function () { favMsg(m); } });
    if (m.kind === 'transfer') items.push({ label: '查看账单详情', run: function () { openBillDetail(transferInfoOf(m.content).id); } });
    if (mine && !m.recalled && (Date.now() - new Date(m.createdAt).getTime()) < 120000) {
      items.push({ label: '撤回', run: function () { recallMsg(m); } });
    }
    items.push({
      label: '删除（只删我这边的记录）',
      run: function () {
        hideMessageLocally(S.activeChat, m.id);
        renderMessages();
        toast('已删除');
      }
    });
    sheet(items);
  }
  /* ---------------- 收藏页 ---------------- */
  /* ---------------- 位置：地图选点（瓦片地图，不依赖第三方 Key） ---------------- */
  var LOC_TILE = 'https://webrd0{s}.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x={x}&y={y}&z={z}';
  var locState = { lat: 39.9087, lng: 116.3975, zoom: 15, drag: null, moved: false };

  function tileUrl(z, x, y, s) {
    return LOC_TILE.replace('{s}', String(s)).replace('{z}', z).replace('{x}', x).replace('{y}', y);
  }
  function lngToX(lng, z) { return (lng + 180) / 360 * Math.pow(2, z); }
  function latToY(lat, z) {
    var r = lat * Math.PI / 180;
    return (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * Math.pow(2, z);
  }
  function xToLng(x, z) { return x / Math.pow(2, z) * 360 - 180; }
  function yToLat(y, z) {
    var n = Math.PI - 2 * Math.PI * y / Math.pow(2, z);
    return 180 / Math.PI * Math.atan(0.5 * (Math.exp(n) - Math.exp(-n)));
  }
  function tileFor(lat, lng, z) {
    var n = Math.pow(2, z);
    var x = Math.floor(lngToX(lng, z));
    var y = Math.floor(latToY(lat, z));
    return { z: z, x: ((x % n) + n) % n, y: Math.max(0, Math.min(n - 1, y)) };
  }
  /** 一张静态缩略图（聊天里的位置卡片用）：取中心 2×2 瓦片拼不出来，就直接用中心那张 */
  function locThumbUrl(lat, lng, z) {
    var t = tileFor(lat, lng, z || 15);
    return tileUrl(t.z, t.x, t.y, 1);
  }
  function locInfoOf(content) {
    var o = {};
    try { o = JSON.parse(content) || {}; } catch (e) { o = {}; }
    return {
      lat: Number(o.lat) || 0, lng: Number(o.lng) || 0,
      name: o.name || '位置', addr: o.addr || ''
    };
  }
  function locLabel() {
    return (locState.lat >= 0 ? '北纬 ' : '南纬 ') + Math.abs(locState.lat).toFixed(5) + '，' +
      (locState.lng >= 0 ? '东经 ' : '西经 ') + Math.abs(locState.lng).toFixed(5);
  }
  function renderLocMap() {
    var box = $('locMap');
    var layer = $('locTiles');
    if (!box || !layer) return;
    var W = box.clientWidth, H = box.clientHeight;
    var z = locState.zoom;
    var scale = Math.pow(2, z) * 256;
    var cx = lngToX(locState.lng, z) * 256;
    var cy = latToY(locState.lat, z) * 256;
    var left = cx - W / 2, top = cy - H / 2;
    var x0 = Math.floor(left / 256), x1 = Math.floor((left + W) / 256);
    var y0 = Math.floor(top / 256), y1 = Math.floor((top + H) / 256);
    var n = Math.pow(2, z);
    var html = '';
    for (var ty = y0; ty <= y1; ty++) {
      if (ty < 0 || ty >= n) continue;
      for (var tx = x0; tx <= x1; tx++) {
        var wx = ((tx % n) + n) % n;
        html += '<img src="' + tileUrl(z, wx, ty, 1) + '" style="left:' + Math.round(tx * 256 - left) + 'px;top:' + Math.round(ty * 256 - top) + 'px" alt="" draggable="false">';
      }
    }
    layer.innerHTML = html;
    $('locCoord').textContent = '拖动地图选点 · ' + locLabel();
    var name = $('locName');
    if (name && (!name.dataset.edited || !name.dataset.edited.length)) {
      name.textContent = pendingLocName || '我的位置';
    }
    try { localStorage.setItem('wx-loc', JSON.stringify({ lat: locState.lat, lng: locState.lng })); } catch (e) { }
  }
  var pendingLocName = '';
  function openLocationPicker(lat, lng, name) {
    if (typeof lat === 'number' && typeof lng === 'number') {
      locState.lat = lat; locState.lng = lng; locState.zoom = 16;
    } else {
      try {
        var saved = JSON.parse(localStorage.getItem('wx-loc') || 'null');
        if (saved && saved.lat) { locState.lat = saved.lat; locState.lng = saved.lng; }
      } catch (e) { /* 忽略 */ }
    }
    pendingLocName = name || '';
    $('locName').textContent = pendingLocName || '我的位置';
    $('locName').dataset.edited = pendingLocName ? '1' : '';
    $('locScreen').hidden = false;
    setTimeout(renderLocMap, 30);
  }
  function bindLocationPicker() {
    var map = $('locMap');
    if (!map) return;
    $('locBack').addEventListener('click', function () { $('locScreen').hidden = true; });
    $('locIn').addEventListener('click', function () { locState.zoom = Math.min(18, locState.zoom + 1); renderLocMap(); });
    $('locOut').addEventListener('click', function () { locState.zoom = Math.max(5, locState.zoom - 1); renderLocMap(); });
    $('locMe').addEventListener('click', function () {
      // 浏览器定位只在 https / localhost 下可用；用不了就回到上次的位置
      if (navigator.geolocation) {
        toast('正在定位…');
        navigator.geolocation.getCurrentPosition(function (pos) {
          locState.lat = pos.coords.latitude; locState.lng = pos.coords.longitude; locState.zoom = 16;
          renderLocMap();
          toast('已定位到当前位置');
        }, function () {
          toast('这个地址（http）拿不到定位，拖动地图选吧');
        }, { timeout: 6000 });
      } else {
        toast('这台设备不支持定位，拖动地图选吧');
      }
    });
    $('locName').addEventListener('click', function () {
      var v = window.prompt('给这个位置起个名（例如：公司、家门口）', $('locName').textContent);
      if (v === null) return;
      pendingLocName = String(v).trim().slice(0, 30) || '我的位置';
      $('locName').textContent = pendingLocName;
      $('locName').dataset.edited = '1';
    });
    $('locGo').addEventListener('click', locSearch);
    $('locQuery').addEventListener('keydown', function (e) { if (e.key === 'Enter') locSearch(); });
    $('locSend').addEventListener('click', function () {
      if (!S.activeChat) { toast('先打开一个聊天'); return; }
      var payload = JSON.stringify({
        lat: Number(locState.lat.toFixed(6)),
        lng: Number(locState.lng.toFixed(6)),
        name: ($('locName').textContent || '我的位置').trim(),
        addr: locLabel()
      });
      sendUploaded('location', payload);
      $('locScreen').hidden = true;
      toast('已发送位置');
    });
    // 拖动 / 双指缩放
    var start = null;
    map.addEventListener('touchstart', function (e) {
      if (e.touches.length === 2) {
        start = { pinch: Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY), zoom: locState.zoom };
        return;
      }
      start = { x: e.touches[0].clientX, y: e.touches[0].clientY, lat: locState.lat, lng: locState.lng };
    }, { passive: true });
    map.addEventListener('touchmove', function (e) {
      if (!start) return;
      if (e.touches.length === 2 && start.pinch) {
        var d = Math.hypot(e.touches[0].clientX - e.touches[1].clientX, e.touches[0].clientY - e.touches[1].clientY);
        var next = Math.max(5, Math.min(18, start.zoom + Math.round(Math.log2(d / start.pinch))));
        if (next !== locState.zoom) { locState.zoom = next; renderLocMap(); }
        return;
      }
      if (e.touches.length !== 1 || !start.x) return;
      var dx = e.touches[0].clientX - start.x, dy = e.touches[0].clientY - start.y;
      var z = locState.zoom;                      // 1 张瓦片 = 256px，位移换算成瓦片数
      locState.lng = xToLng(lngToX(start.lng, z) - dx / 256, z);
      locState.lat = yToLat(latToY(start.lat, z) - dy / 256, z);
      renderLocMap();
    }, { passive: true });
    var endDrag = function () { start = null; };
    map.addEventListener('touchend', endDrag, { passive: true });
    map.addEventListener('touchcancel', endDrag, { passive: true });
    // 鼠标也能拖（电脑 / 调试）
    var mStart = null;
    map.addEventListener('mousedown', function (e) { mStart = { x: e.clientX, y: e.clientY, lat: locState.lat, lng: locState.lng }; });
    window.addEventListener('mouseup', function () { mStart = null; });
    window.addEventListener('mousemove', function (e) {
      if (!mStart) return;
      var z = locState.zoom;
      locState.lng = xToLng(lngToX(mStart.lng, z) - (e.clientX - mStart.x) / 256, z);
      locState.lat = yToLat(latToY(mStart.lat, z) - (e.clientY - mStart.y) / 256, z);
      renderLocMap();
    });
  }
  /** 搜索地点：用 OpenStreetMap 的公开检索（不用 key），失败就让用户手动拖 */
  function locSearch() {
    var q = ($('locQuery').value || '').trim();
    if (!q) { toast('先输入要搜的地点'); return; }
    toast('正在搜索…');
    fetch('https://nominatim.openstreetmap.org/search?format=json&limit=5&accept-language=zh-CN&q=' + encodeURIComponent(q))
      .then(function (r) { return r.json(); })
      .then(function (list) {
        if (!list || !list.length) { toast('没搜到，试试拖动地图选点'); return; }
        sheet(list.map(function (it) {
          return {
            label: String(it.display_name || '').slice(0, 40),
            run: function () {
              locState.lat = Number(it.lat); locState.lng = Number(it.lon); locState.zoom = 16;
              pendingLocName = String(it.display_name || '').split(',')[0].slice(0, 24) || '位置';
              $('locName').textContent = pendingLocName;
              $('locName').dataset.edited = '1';
              renderLocMap();
            }
          };
        }));
      })
      .catch(function () { toast('搜索服务连不上，直接拖动地图选点吧'); });
  }

  function locationBubble(content) {
    var o = locInfoOf(content);
    return '<div class="wx-bubble is-loc" data-loc="' + o.lat + ',' + o.lng + '" data-locname="' + esc(o.name) + '">' +
      '<div class="loc-thumb"><img src="' + esc(locThumbUrl(o.lat, o.lng, 15)) + '" alt="" loading="lazy" decoding="async"><span class="loc-mark"></span></div>' +
      '<div class="loc-info"><div class="loc-t1">' + esc(o.name) + '</div>' +
      '<div class="loc-t2">' + esc(o.addr || '点击查看地图') + '</div></div></div>';
  }

  function favTime(iso) {
    var d = new Date(iso);
    if (!iso || isNaN(d.getTime())) return '';
    var p = function (n) { return (n < 10 ? '0' : '') + n; };
    return (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }
  function loadFavorites() {
    var box = $('favList');
    if (!box) return;
    box.innerHTML = '<div class="fav-empty">正在读取…</div>';
    api('/favorites').then(function (d) {
      var list = (d && d.favorites) || [];
      if (!list.length) { box.innerHTML = '<div class="fav-empty">还没有收藏，聊天里长按消息就能收藏</div>'; return; }
      box.innerHTML = list.map(function (f) {
        var head = f.kind === 'image'
          ? '<div class="fav-img" data-fav-img="' + esc(f.content) + '"><img src="' + esc(f.content) + '" alt="" loading="lazy" decoding="async"></div>'
          : '';
        var text = f.kind === 'image' ? '［图片］' : (f.kind === 'transfer' ? ('［转账］¥' + (Number(transferInfoOf(f.content).amount) || 0).toFixed(2)) : esc(f.content));
        return '<div class="fav-item">' + head +
          '<div class="fav-main"><div class="fav-text">' + text + '</div>' +
          '<div class="fav-meta">' + esc(f.title || '') + (f.at ? ' · ' + favTime(f.at) : '') + '</div></div>' +
          '<button class="fav-del" data-fav-del="' + esc(f.id) + '">删除</button>' +
          '</div>';
      }).join('');
    }).catch(function (e) {
      box.innerHTML = '<div class="fav-empty">' + esc(e.message || '读取失败') + '</div>';
    });
  }
  function openFavorites() {
    $('favScreen').hidden = false;
    loadFavorites();
  }
  function bindMsgLongPress() {
    $('favBack').addEventListener('click', function () { $('favScreen').hidden = true; });
    $('favList').addEventListener('click', function (e) {
      var del = e.target.closest('[data-fav-del]');
      if (del) {
        api('/favorites/' + encodeURIComponent(del.getAttribute('data-fav-del')), { method: 'DELETE' })
          .then(function () { loadFavorites(); toast('已从收藏里移除'); })
          .catch(function (err) { toast(err.message || '删除失败'); });
        return;
      }
      var img = e.target.closest('[data-fav-img]');
      if (img) {
        var src = img.getAttribute('data-fav-img');
        var all = [].slice.call(document.querySelectorAll('[data-fav-img]')).map(function (x) { return x.getAttribute('data-fav-img'); });
        openPhotos(all, Math.max(0, all.indexOf(src)));
      }
    });
    var box = $('messages');
    if (!box) return;
    box.addEventListener('touchstart', function (e) {
      var row = e.target.closest('.wx-msg');
      if (!row) return;
      var id = row.getAttribute('data-id');
      if (!id) return;
      lpStart = { x: e.touches[0].clientX, y: e.touches[0].clientY };
      clearTimeout(lpTimer);
      lpTimer = setTimeout(function () {
        lpTimer = null;
        if (navigator.vibrate) { try { navigator.vibrate(12); } catch (err) { } }
        openMsgMenu(id);
      }, 470);
    }, { passive: true });
    box.addEventListener('touchmove', function (e) {
      if (!lpStart || !lpTimer) return;
      if (Math.abs(e.touches[0].clientX - lpStart.x) > 10 || Math.abs(e.touches[0].clientY - lpStart.y) > 10) {
        clearTimeout(lpTimer); lpTimer = null;
      }
    }, { passive: true });
    var stop = function () { clearTimeout(lpTimer); lpTimer = null; };
    box.addEventListener('touchend', stop, { passive: true });
    box.addEventListener('touchcancel', stop, { passive: true });
    // 电脑端 / 鼠标：右键也能出菜单
    box.addEventListener('contextmenu', function (e) {
      var row = e.target.closest('.wx-msg');
      if (!row) return;
      e.preventDefault();
      openMsgMenu(row.getAttribute('data-id'));
    });
  }

  /* ---------------- 转账气泡（橙色卡片，微信那种） ---------------- */
  function transferInfoOf(content) {
    var t = {};
    try { t = JSON.parse(content) || {}; } catch (e) { t = {}; }
    return {
      id: t.id || '', amount: Number(t.amount) || 0, note: t.note || '',
      status: t.status || 'pending', fromId: t.fromId || '', toId: t.toId || '',
      method: t.method || 'balance',
      createdAt: t.createdAt || '', expiresAt: t.expiresAt || 0,
      receivedAt: t.receivedAt || '', refundedAt: t.refundedAt || ''
    };
  }
  /* 转账/红包气泡的状态：收了钱、退回之后，直接把气泡改成对应颜色（不用重进聊天） */
  function updateTransferBubbles(id, status) {
    var nodes = document.querySelectorAll('.wx-bubble.is-transfer[data-transfer="' + id + '"]');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var mine = el.getAttribute('data-mine') === '1';
      el.setAttribute('data-status', status);
      el.classList.remove('is-done', 'is-back');
      var state;
      if (status === 'received') {
        el.classList.add('is-done');
        state = mine ? '对方已收款' : '已收款，钱已到你余额';
      } else if (status === 'refunded') {
        el.classList.add('is-back');
        state = mine ? '超过 24 小时未收款，已退回你的余额' : '已退回对方';
      } else {
        state = mine ? '待对方确认收款 · 24 小时未收款自动退回' : '24 小时未收款自动退回';
      }
      var st = el.querySelector('.tb-state');
      if (st) st.textContent = state;
      var btn = el.querySelector('.tb-btn');
      if (btn && status !== 'pending') btn.remove();
    }
  }

  /* ---------------- 红包（微信那套）：拼手气 / 普通、群红包、限领一次、24 小时退回 ---------------- */
  var payMode = 'transfer';        // transfer 转账 / redpacket 发红包
  var rpDraft = { amount: 0, count: 1, lucky: true, note: '恭喜发财，大吉大利' };

  function rpInfoOf(content) { try { return JSON.parse(content) || {}; } catch (e) { return {}; } }

  function rpCard(content, mine) {
    var r = rpInfoOf(content);
    var total = Number(r.total != null ? r.total : r.amount) || 0;
    var count = Number(r.count) || 1;
    var claimedCount = Number(r.claimedCount) || 0;
    var ids = r.claimedIds || [];
    var myId = (S.me && S.me.id) || '';
    var mineClaimed = ids.indexOf(myId) >= 0;
    var over = !!r.expired || r.status === 'done' || r.status === 'refunded' || r.status === 'received' || claimedCount >= count;
    var pale = mineClaimed || over;
    var state = mineClaimed ? '已领取' : (r.expired ? '已过期' : (over ? '红包已被领完' : '领取红包'));
    var note = r.note || '恭喜发财，大吉大利';
    var bg = pale ? 'linear-gradient(180deg,#F7BE8F,#F0AE79)' : 'linear-gradient(180deg,#FA9D3C,#F2882A)';
    return '<div class="wx-bubble is-rp" data-rp="' + esc(String(r.id || '')) + '" data-mine="' + (mine ? '1' : '0') + '"' +
      ' style="width:236px;background:' + bg + ';color:#fff;border-radius:6px;overflow:hidden;padding:0">' +
      '<div style="display:flex;gap:10px;padding:12px 12px 10px">' +
        '<div style="width:30px;height:38px;flex:0 0 30px;border-radius:5px;background:#E95A45;position:relative">' +
          '<div style="position:absolute;left:50%;top:42%;transform:translateX(-50%);width:11px;height:11px;border-radius:50%;background:#F7C948"></div>' +
        '</div>' +
        '<div style="min-width:0">' +
          '<div style="font-size:15.5px;line-height:1.25;word-break:break-all">' + esc(note) + '</div>' +
          (count > 1 ? '<div style="font-size:11.5px;opacity:.75;margin-top:4px">共 ' + count + ' 个</div>' : '') +
        '</div>' +
      '</div>' +
      '<div style="border-top:1px solid rgba(255,255,255,.22);display:flex;align-items:center;height:30px;padding:0 12px;font-size:11.5px">' +
        '<span style="opacity:.8">' + (r.type === 'lucky' ? '拼手气红包' : '普通红包') + '</span>' +
        '<span style="margin-left:auto;font-size:12.5px">' + state + '</span>' +
      '</div>' +
    '</div>';
  }

  /* 点红包卡片：还能抢就直接拆，领过 / 领完 / 自己发的 → 看详情 */
  function onRedPacketTap(id) {
    var msg = null;
    (S.messages || []).forEach(function (m) { if (m.kind === 'redpacket' && rpInfoOf(m.content).id === id) msg = m; });
    var r = msg ? rpInfoOf(msg.content) : {};
    if (!r.id) { toast('这条红包记录是旧版本的，已经失效'); return; }
    var myId = (S.me && S.me.id) || '';
    var claimed = (r.claimedIds || []).indexOf(myId) >= 0;
    var over = !!r.expired || r.status === 'done' || r.status === 'refunded' || r.status === 'received' ||
      (Number(r.claimedCount) || 0) >= (Number(r.count) || 1);
    if (!claimed && !over && r.fromId !== myId) { rpOpenSheet(r.id); }
    else { rpDetailSheet(r.id); }
  }

  /* 通用弹层：底部一张白卡（红包相关的几个界面都用它） */
  function rpSheet(inner, onClose) {
    var box = document.createElement('div');
    box.setAttribute('data-rp-sheet', '1');
    box.style.cssText = 'position:fixed;inset:0;z-index:4000;background:rgba(0,0,0,.45);display:flex;align-items:flex-end';
    box.innerHTML = '<div style="background:#fff;width:100%;border-radius:14px 14px 0 0;max-height:82vh;overflow:auto">' + inner + '</div>';
    document.body.appendChild(box);
    function close() { box.remove(); if (onClose) onClose(); }
    box.addEventListener('click', function (e) { if (e.target === box) close(); });
      var x = box.querySelector('[data-rp-close]');
      if (x) x.addEventListener('click', close);
      return { box: box, close: close };
    }

  function rpHead(title) {
    return '<div style="display:flex;align-items:center;padding:14px 16px 6px">' +
      '<div style="font-size:16px;font-weight:600">' + esc(title) + '</div>' +
      '<button data-rp-close style="margin-left:auto;border:0;background:none;font-size:20px;color:#999;line-height:1">×</button></div>';
  }

  /* 发红包：金额 / 个数（群）/ 祝福语 / 拼手气·普通 → 塞钱进红包（走支付密码） */
  function openRedPacketSend() {
    var chat = S.chats.filter(function (c) { return c.id === S.activeChat; })[0] || {};
    var isGroup = chat.type === 'group';
    rpDraft = { amount: 0, count: 1, lucky: true, note: '恭喜发财，大吉大利' };
    var field = 'style="width:100%;border:1px solid #E5E5E5;border-radius:8px;padding:10px 12px;font-size:16px;box-sizing:border-box"';
    var inner = rpHead('发红包') +
      '<div style="padding:6px 16px 18px">' +
        '<div style="font-size:12.5px;color:#999;margin:2px 0 6px">金额（元）</div>' +
        '<input id="rpAmount" inputmode="decimal" placeholder="0.00" ' + field + '>' +
        (isGroup ? '<div style="font-size:12.5px;color:#999;margin:12px 0 6px">个数</div>' +
          '<input id="rpCount" inputmode="numeric" value="1" ' + field + '>' : '') +
        '<div style="font-size:12.5px;color:#999;margin:12px 0 6px">祝福语</div>' +
        '<input id="rpNote" value="恭喜发财，大吉大利" ' + field + '>' +
        (isGroup ? '<div id="rpType" style="display:flex;gap:8px;margin-top:14px">' +
          '<button data-t="lucky" style="flex:1;padding:9px;border-radius:8px;border:1px solid #E95A45;background:#FDEDE9;color:#C8371F;font-size:14px">拼手气红包</button>' +
          '<button data-t="normal" style="flex:1;padding:9px;border-radius:8px;border:1px solid #E5E5E5;background:#fff;color:#666;font-size:14px">普通红包</button>' +
        '</div>' : '') +
        '<button id="rpGo" style="width:100%;margin-top:18px;padding:13px;border:0;border-radius:8px;background:#E23B2E;color:#fff;font-size:16px">塞钱进红包</button>' +
        '<div id="rpTip" style="font-size:12.5px;color:#E23B2E;margin-top:8px;min-height:16px"></div>' +
        '<div style="font-size:12px;color:#999;margin-top:6px">' +
          (isGroup ? '拼手气：总金额随机分；普通红包：每人一样。24 小时没抢完，剩下的自动退回。' : '单聊红包只能发 1 个。24 小时没被领，钱自动退回。') +
        '</div>' +
      '</div>';
    var sh = rpSheet(inner);
    var typeBox = sh.box.querySelector('#rpType');
    if (typeBox) {
      typeBox.addEventListener('click', function (e) {
        var b = e.target.closest('[data-t]');
        if (!b) return;
        rpDraft.lucky = b.getAttribute('data-t') === 'lucky';
        [].forEach.call(typeBox.querySelectorAll('[data-t]'), function (x) {
          var on = x === b;
          x.style.border = '1px solid ' + (on ? '#E95A45' : '#E5E5E5');
          x.style.background = on ? '#FDEDE9' : '#fff';
          x.style.color = on ? '#C8371F' : '#666';
        });
      });
    }
    sh.box.querySelector('#rpGo').addEventListener('click', function () {
      var amount = Number((sh.box.querySelector('#rpAmount').value || '').replace(/[^\d.]/g, '')) || 0;
      var count = isGroup ? Math.round(Number(sh.box.querySelector('#rpCount').value) || 1) : 1;
      var note = (sh.box.querySelector('#rpNote').value || '').trim() || '恭喜发财，大吉大利';
      var tip = sh.box.querySelector('#rpTip');
      if (!(amount > 0)) { tip.textContent = '先填金额'; return; }
      if (count < 1 || count > 100) { tip.textContent = '个数填 1~100'; return; }
      if (amount < count * 0.01) { tip.textContent = '每个红包最少 0.01 元'; return; }
      if (!rpDraft.lucky && count > 1) {
        var each = Math.round(amount / count * 100) / 100;
        if (Math.abs(each * count - amount) > 0.005) {
          tip.textContent = '普通红包要能平分：' + count + ' 个 × ' + each.toFixed(2) + ' 元';
          return;
        }
      }
      rpDraft.amount = amount; rpDraft.count = count; rpDraft.note = note;
      payMode = 'redpacket';
      payValue = amount;
      sh.close();
      openPaySheet();
    });
  }

  /* 拆红包：点「开」才进零钱 */
  function rpOpenSheet(id) {
    var inner =
      '<div style="background:linear-gradient(180deg,#E4553C,#B8381F);color:#F7DFA0;text-align:center;padding:20px 16px 26px;border-radius:14px 14px 0 0">' +
        '<div style="font-size:14px">点「开」，钱直接进你的零钱</div>' +
        '<button id="rpOpenBtn" style="margin:18px auto 0;display:block;width:104px;height:104px;border-radius:50%;border:2px solid #FFF3CF;background:linear-gradient(180deg,#FFE9B0,#E9B84C);color:#8A3A12;font-size:30px;font-weight:600">开</button>' +
        '<div id="rpOpenAmt" style="font-size:30px;font-weight:600;color:#8A3A12;margin-top:18px;display:none"></div>' +
        '<div id="rpOpenTip" style="font-size:13px;margin-top:10px;min-height:18px"></div>' +
        '<button data-rp-close style="margin-top:14px;border:0;background:transparent;color:#F7DFA0;font-size:14px">关闭</button>' +
      '</div>';
    var sh = rpSheet(inner);
    sh.box.querySelector('#rpOpenBtn').addEventListener('click', function () {
      var btn = this;
      if (btn.disabled) return;
      btn.disabled = true;
      btn.textContent = '…';
      api('/redpackets/' + id + '/claim', { method: 'POST', body: JSON.stringify({}) }).then(function (d) {
        if (S.me && d.balance !== undefined) S.me.balance = Number(d.balance) || 0;
        btn.style.display = 'none';
        var amt = sh.box.querySelector('#rpOpenAmt');
        amt.style.display = 'block';
        amt.textContent = '¥' + (Number(d.amount) || 0).toFixed(2);
        sh.box.querySelector('#rpOpenTip').textContent = '已存入零钱';
        loadChats(); renderMessages();
      }).catch(function (e) {
        btn.disabled = false;
        btn.textContent = '开';
        sh.box.querySelector('#rpOpenTip').textContent = e.message || '没抢到';
      });
    });
  }

  /* 红包详情：谁抢了多少、手气最佳 */
  function rpDetailSheet(id) {
    api('/redpackets/' + id).then(function (d) {
      var r = d.redpacket || {};
      var myId = (S.me && S.me.id) || '';
      var claims = r.claims || [];
      var rows = claims.map(function (c) {
        var best = r.bestUserId && r.bestUserId === c.userId && claims.length > 1;
        return '<div style="display:flex;align-items:center;padding:10px 16px;border-top:1px solid #F2F2F2">' +
          '<div style="min-width:0">' +
            '<div style="font-size:15px">' + esc(c.name || '好友') +
              (best ? ' <span style="font-size:10.5px;color:#fff;background:#E2A03C;border-radius:9px;padding:1px 6px">手气最佳</span>' : '') +
            '</div>' +
            '<div style="font-size:12px;color:#999">' + esc(String(c.at || '').slice(5, 16).replace('T', ' ')) + '</div>' +
          '</div>' +
          '<div style="margin-left:auto;font-size:15px">¥' + (Number(c.amount) || 0).toFixed(2) + '</div>' +
        '</div>';
      }).join('') || '<div style="padding:24px 16px;color:#999;font-size:14px">还没有人抢到这个红包</div>';
      var mine = claims.filter(function (c) { return c.userId === myId; })[0];
      var status = r.expired ? ('共 ' + (r.count || 1) + ' 个，已领 ' + (r.claimedCount || 0) + ' 个 · 已过期')
        : (r.status === 'done' ? ('共 ' + (r.count || 1) + ' 个，已经领完') : ('共 ' + (r.count || 1) + ' 个，已领 ' + (r.claimedCount || 0) + ' 个'));
      var inner =
        '<div style="background:linear-gradient(180deg,#FBEFD8,#F7E2C0);text-align:center;padding:18px 16px 20px;border-radius:14px 14px 0 0">' +
          '<div style="font-size:15px;font-weight:600">' + esc(r.fromName || '好友') + '</div>' +
          '<div style="font-size:14px;color:#8A6A3A;margin-top:4px">' + esc(r.note || '恭喜发财，大吉大利') + '</div>' +
          '<div style="font-size:12.5px;color:#8A6A3A;opacity:.85;margin-top:6px">' + esc(status) + '</div>' +
          (mine ? '<div style="font-size:15px;color:#C8371F;margin-top:8px">我抢到 ¥' + (Number(mine.amount) || 0).toFixed(2) + '</div>' : '') +
        '</div>' +
        '<div>' + rows + '</div>' +
        '<div style="padding:12px 16px;font-size:12px;color:#999;text-align:center">' +
          (r.expired && r.refundAmount > 0 ? ('没被抢走的 ¥' + Number(r.refundAmount).toFixed(2) + ' 已经退回给发红包的人')
            : (r.status === 'pending' ? ('还有 ' + (r.leftCount || 0) + ' 个没被领 · 未领完 24 小时后自动退回') : '红包里的钱已经全部领走了')) +
        '</div>' +
        '<div style="padding:0 16px 18px"><button data-rp-close style="width:100%;padding:12px;border:0;border-radius:8px;background:#F2F2F2;color:#333;font-size:15px">关闭</button></div>';
      rpSheet(inner);
    }).catch(function (e) { toast(e.message || '打不开红包详情'); });
  }

  function transferBubble(content, mine) {
    var t = transferInfoOf(content);
    var desc = mine ? '你发起了一笔转账' : '转账给你';
    var state = mine ? '待对方确认收款 · 24 小时未收款自动退回' : '24 小时未收款自动退回';
    var cls = '';
    if (t.status === 'received') { cls = ' is-done'; state = mine ? '对方已收款' : '已收款，钱已到你余额'; }
    else if (t.status === 'refunded') { cls = ' is-back'; state = mine ? '超过 24 小时未收款，已退回你的余额' : '已退回对方'; }
    return '<div class="wx-bubble is-transfer' + cls + '" data-transfer="' + esc(t.id) + '" data-status="' + esc(t.status) +
      '" data-amount="' + t.amount.toFixed(2) + '" data-mine="' + (mine ? '1' : '0') + '">' +
      '<div class="tb-inner">' +
        '<span class="tb-icon">' +
          '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">' +
            '<path d="M4.2 8.6h13.2M14.6 5.4l3.2 3.2-3.2 3.2"/>' +
            '<path d="M19.8 15.4H6.6M9.4 12.2L6.2 15.4l3.2 3.2"/>' +
          '</svg>' +
        '</span>' +
        '<span class="tb-text">' +
          '<span class="tb-amount">¥' + t.amount.toFixed(2) + '</span>' +
          '<span class="tb-desc">' + esc(desc) + (t.note ? ' · ' + esc(t.note) : '') + '</span>' +
        '</span>' +
      '</div>' +
      '<div class="tb-foot">' +
        '<span class="tb-label">转账</span>' +
        '<span class="tb-state">' + esc(state) + '</span>' +
        (!mine && t.status === 'pending' ? '<span class="tb-btn">收钱</span>' : '') +
      '</div>' +
      '</div>';
  }

  /** 点转账气泡：打开「转账详情」页（没收款之前那一页）；点白按钮「收钱」直接收 */
  function onTransferTap(card, ev) {
    var id = card.getAttribute('data-transfer');
    if (ev && ev.target && ev.target.closest('.tb-btn')) { claimTransfer(id); return; }
    openTransferDetail(id);
  }

  /* ---------------- 转账详情页 ---------------- */
  var tdCurrent = null;

  function fmtTransferTime(iso) {
    var d = new Date(iso);
    if (!iso || isNaN(d.getTime())) return '—';
    var p = function (n) { return (n < 10 ? '0' : '') + n; };
    return d.getFullYear() + '年' + p(d.getMonth() + 1) + '月' + p(d.getDate()) + '日 ' +
      p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }
  function leftText(expiresAt) {
    var ms = Number(expiresAt) - Date.now();
    if (!(ms > 0)) return '已到期';
    var h = Math.floor(ms / 3600000), m = Math.floor((ms % 3600000) / 60000);
    if (h >= 24) return '1天内';
    if (h >= 1) return h + '小时' + (m ? m + '分' : '');
    return m + '分钟';
  }
  function findTransfer(id) {
    var list = S.messages[S.activeChat] || [];
    for (var i = 0; i < list.length; i++) {
      var t = transferInfoOf(list[i].content);
      if (t.id === id) return { t: t, msg: list[i] };
    }
    return null;
  }
  function openTransferDetail(id) {
    var hit = findTransfer(id);
    if (!hit) { toast('这条转账的记录没找到'); return; }
    var t = hit.t;
    var mine = hit.msg ? hit.msg.senderId === S.me.id : true;
    var chat = S.chats.filter(function (c) { return c.id === S.activeChat; })[0] || {};
    var peer = chat.title || '对方';
    var senderName = hit.msg && hit.msg.senderName ? hit.msg.senderName : peer;
    tdCurrent = { id: t.id, mine: mine, amount: t.amount, status: t.status };
    /* 金额：数字 50 / ¥ 34（参考图），小数点画成方点 */
    (function () {
      var parts = t.amount.toFixed(2).split('.');
      $('tdAmount').innerHTML = '<span class="cur">¥</span>' + parts[0]
        + '<i class="dot"></i>' + (parts[1] || '00');
    })();
    $('tdTime').textContent = fmtTransferTime(t.createdAt);
    $('tdNo').textContent = String(t.id || '').replace(/^tr_/, '').toUpperCase();
    $('tdNoteRow').hidden = !t.note;
    if (t.note) $('tdNote').textContent = t.note;
    var act = $('tdAction');
    if (t.status === 'pending') {
      if (mine) {
        $('tdTitle').textContent = '待' + peer + '收款';
        $('tdHint').textContent = leftText(t.expiresAt).replace(/内$/, '') + '内对方未收款，将退还给你。';
        act.textContent = '提醒对方收款'; act.hidden = false;
      } else {
        $('tdTitle').textContent = senderName + '向你转账';
        $('tdHint').textContent = leftText(t.expiresAt).replace(/内$/, '') + '内未收款，将退还对方。';
        act.textContent = '立即收款'; act.hidden = false;
      }
      $('tdState').textContent = '钱已经从付款方余额扣下，等你收款 ✓';
    } else if (t.status === 'received') {
      $('tdTitle').textContent = mine ? '对方已收款' : '已收款';
      $('tdHint').textContent = '钱已存入' + (mine ? '对方' : '你的') + '零钱余额。';
      act.hidden = true;
      $('tdState').textContent = t.receivedAt ? ('收款时间 ' + fmtTransferTime(t.receivedAt)) : '';
    } else {
      $('tdTitle').textContent = mine ? '已退回你的余额' : '已退回对方';
      $('tdHint').textContent = '超过 24 小时未收款，钱已原路退回。';
      act.hidden = true;
      $('tdState').textContent = t.refundedAt ? ('退回时间 ' + fmtTransferTime(t.refundedAt)) : '';
    }
    $('tfDetailScreen').hidden = false;
  }
  function bindTransferDetail() {
    $('billBack').addEventListener('click', function () { $('billScreen').hidden = true; });
    $('billAll').addEventListener('click', billHistory);
    $('blAction').addEventListener('click', function () {
      if (!billCurrent || billCurrent.status !== 'pending') return;
      if (billCurrent.mine) { toast('已提醒对方收款'); return; }
      claimTransfer(billCurrent.id);
    });
    document.querySelectorAll('[data-bill-svc]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var kind = btn.getAttribute('data-bill-svc');
        if (kind === 'doubt') { toast('有疑问可以先联系对方，或让管理员在后台查这笔单号'); return; }
        if (kind === 'history') { billHistory(); return; }
        // 定位到聊天位置：关掉账单和详情页，回到聊天里那条转账
        $('billScreen').hidden = true;
        $('tfDetailScreen').hidden = true;
        var id = billCurrent && billCurrent.id;
        var box = document.querySelector('.wx-bubble.is-transfer[data-transfer="' + id + '"]');
        if (box && box.scrollIntoView) box.scrollIntoView({ block: 'center', behavior: 'smooth' });
      });
    });
    $('tdBack').addEventListener('click', function () { $('tfDetailScreen').hidden = true; });
    $('tdMore').addEventListener('click', function () {
      if (!tdCurrent) return;
      sheet([
        { label: '刷新状态', run: function () { if (tdCurrent) openTransferDetail(tdCurrent.id); } },
        { label: '关闭', run: function () { $('tfDetailScreen').hidden = true; } }
      ]);
    });
    $('tdAction').addEventListener('click', function () {
      if (!tdCurrent) return;
      if (tdCurrent.status !== 'pending') return;
      if (tdCurrent.mine) { toast('已提醒对方收款'); return; }
      claimTransfer(tdCurrent.id);
    });
    $('tdBill').addEventListener('click', function () {
      if (!tdCurrent) return;
      openBillDetail(tdCurrent.id);
    });
  }

  /* ---------------- 账单详情页（照参考图：头像 + 转账-转给XX + 金额 + 字段 + 账单服务） ---------------- */
  var billCurrent = null;
  function payMethodName(m) { return m === 'card' ? '建设银行储蓄卡(2125)' : '零钱'; }
  function billStatusText(t, mine) {
    if (t.status === 'pending') return mine ? '等待对方确认收钱' : '等待你确认收钱';
    if (t.status === 'received') return '已收款';
    return '已退回';
  }
  function openBillDetail(id) {
    var hit = findTransfer(id);
    /* 从「账单」列表点进来的：聊天里没这条记录，就用 /api/bills 那份数据 */
    var bill = (S.billById || {})[id];
    if (!hit && !bill) { toast('这笔账单没找到'); return; }
    var t = hit ? hit.t : bill;
    var mine = hit ? (hit.msg ? hit.msg.senderId === S.me.id : true) : (bill.direction === 'out');
    var chat = S.chats.filter(function (c) { return c.id === S.activeChat; })[0] || {};
    var peer;
    var who;
    if (hit) {
      peer = chat.title || '对方';
      var senderName = hit.msg && hit.msg.senderName ? hit.msg.senderName : peer;
      who = mine ? peer : senderName;
    } else {
      peer = bill.peerName || '对方';
      who = peer;
    }
    var face = hit ? (chat.avatar || '') : (bill.peerAvatar || '');
    $('blAvatar').innerHTML = face
      ? '<img src="' + esc(face) + '" alt="" decoding="async">'
      : esc((who || '?').trim().slice(0, 1));
    $('blType').textContent = mine ? ('转账-转给' + who) : ('转账-来自' + who);
    $('blAmount').textContent = (mine ? '-' : '+') + '¥' + t.amount.toFixed(2);
    $('blState').textContent = billStatusText(t, mine) +
      (t.status === 'pending' ? '（' + leftText(t.expiresAt) + '后自动退回）' : '');
    $('blNote').textContent = t.note || '微信转账';
    $('blTime').textContent = fmtBillTime(t.createdAt);
    $('blMethod').textContent = payMethodName(t.method);
    $('blNo').textContent = billNo(t);
    $('blRecvRow').hidden = t.status !== 'received';
    if (t.status === 'received') $('blRecvAt').textContent = fmtBillTime(t.receivedAt);
    $('blBackRow').hidden = t.status !== 'refunded';
    if (t.status === 'refunded') $('blBackAt').textContent = fmtBillTime(t.refundedAt);
    var act = $('blAction');
    act.hidden = t.status !== 'pending';
    if (t.status === 'pending') act.textContent = mine ? '提醒对方收款' : '立即收款';
    billCurrent = { id: id, mine: mine, peer: who, amount: t.amount, status: t.status };
    $('billScreen').hidden = false;
  }
  /** 账单里的时间：2026年9月13日 13:11:57（参考图不带前导 0） */
  function fmtBillTime(iso) {
    var d = new Date(iso);
    if (!iso || isNaN(d.getTime())) return '—';
    var p = function (n) { return (n < 10 ? '0' : '') + n; };
    return d.getFullYear() + '年' + (d.getMonth() + 1) + '月' + d.getDate() + '日 ' +
      p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }
  /** 参考图里的转账单号是 1000050001 + 日期 + 一串数字 */
  function billNo(t) {
    var d = new Date(t.createdAt);
    var stamp = isNaN(d.getTime()) ? '00000000000000'
      : ('' + d.getFullYear() + (d.getMonth() + 1 < 10 ? '0' : '') + (d.getMonth() + 1) +
        (d.getDate() < 10 ? '0' : '') + d.getDate() +
        (d.getHours() < 10 ? '0' : '') + d.getHours() +
        (d.getMinutes() < 10 ? '0' : '') + d.getMinutes() +
        (d.getSeconds() < 10 ? '0' : '') + d.getSeconds());
    var tail = String(t.id || '').replace(/^tr_/, '').toUpperCase();
    return '1000050001' + stamp + tail;
  }
  function billHistory() {
    var list = (S.messages[S.activeChat] || []).map(function (m) {
      var t = transferInfoOf(m.content);
      return t.id ? { t: t, mine: m.senderId === S.me.id } : null;
    }).filter(Boolean).reverse();
    if (!list.length) { toast('这个聊天里还没有转账'); return; }
    sheet(list.slice(0, 12).map(function (x) {
      var label = (x.mine ? '转出 ' : '收入 ') + '¥' + x.t.amount.toFixed(2) + ' · ' +
        (x.t.status === 'pending' ? '待收款' : (x.t.status === 'received' ? '已收款' : '已退回')) +
        ' · ' + fmtBillTime(x.t.createdAt);
      return { label: label, run: function () { openBillDetail(x.t.id); } };
    }));
  }

  function claimTransfer(id) {
    api('/transfers/' + encodeURIComponent(id) + '/claim', { method: 'POST' })
      .then(function (d) {
        if (d && d.balance !== undefined && S.me) S.me.balance = Number(d.balance) || 0;
        var amt = d && d.transfer ? Number(d.transfer.amount) || 0 : 0;
        toast('已收款 ' + money(amt));
        /* 收完钱，本地那条转账消息也要改成「已收款」：
           气泡颜色立刻从橙色变成已收款的浅色（以前要退出聊天再进来才变） */
        if (d && d.transfer) {
          var list = S.messages[S.activeChat] || [];
          for (var i = 0; i < list.length; i++) {
            if (list[i].kind !== 'transfer') continue;
            var ti = transferInfoOf(list[i].content);
            if (ti && ti.id === id) { list[i].content = JSON.stringify(d.transfer); break; }
          }
          if ($('chatScreen') && !$('chatScreen').hidden) renderMessages();
          updateTransferBubbles(id, 'received');
        }
        if (tdCurrent && tdCurrent.id === id) openTransferDetail(id);   // 详情页开着就刷成「已收款」
      })
      .catch(function (e) { toast(e.message || '收款失败'); });
  }

  function giftInfoOf(content) {
    var g;
    try { g = JSON.parse(content) || {}; } catch (e) { g = { name: String(content || '礼物') }; }
    return { id: g.id || '', icon: g.icon || '🎁', name: g.name || '礼物', price: Number(g.price) || 0 };
  }

  /* 跑车 / 飞机 / 火箭这三种走专属特效（图标或名字里有对应关键字就算） */
  function giftFloodKind(g) {
    var s = String((g && g.icon) || '') + String((g && g.name) || '');
    if (/🏎|🚗|🚕|🚙|🚌|跑车|赛车|汽车|豪车/.test(s)) return 'car';
    if (/✈|🛩|🛫|🛬|飞机|航班|客机|直升机|🚁/.test(s)) return 'plane';
    if (/🚀|🛰|火箭|飞船|飞行器/.test(s)) return 'rocket';
    if (/🎆|🎇|烟花|礼花|爆竹/.test(s)) return 'firework';
    return '';
  }

  function giftFloodFx(kind) {
    if (kind === 'car') {
      var rows = [[-28, 74, 160, 150], [-13, 96, 200, 120], [4, 64, 140, 100], [19, 104, 220, 165],
        [-36, 52, 118, 130], [27, 84, 178, 140], [11, 122, 248, 190], [-21, 98, 205, 155]];
      var streaks = rows.map(function (r, i) {
        return '<i style="top:' + r[0] + 'px; width:' + r[1] + 'px; --x0:' + (-r[2]) + 'px; --x1:' + r[3] + 'px; --d:' + (0.05 * i).toFixed(2) + 's"></i>';
      }).join('');
      return '<div class="gf-road"></div><div class="gf-road gf-road-2"></div><div class="gf-streaks">' + streaks + '</div>';
    }
    if (kind === 'plane') {
      var clouds = [[-92, -30, 0], [70, 26, 0.12], [-46, 46, 0.24], [104, -6, 0.36]].map(function (c) {
        return '<i style="left:' + c[0] + 'px; top:' + c[1] + 'px; --d:' + c[2] + 's">☁️</i>';
      }).join('');
      return '<div class="gf-contrail"></div><div class="gf-contrail is-b"></div><div class="gf-clouds">' + clouds + '</div>';
    }
    if (kind === 'rocket') return '<div class="gf-flame"></div>';
    if (kind === 'firework') return giftFireworkFx();
    return '';
  }

  /* 烟花：满屏连发——11 发自下往上升空炸开，每发 15 颗火星往外飞再下坠 */
  function giftFireworkFx() {
    if (typeof window === 'undefined') return '';
    var W = window.innerWidth, H = window.innerHeight;
    var palette = [
      ['#ffd166', '#ff8fab'], ['#7ee8fa', '#80ffdb'], ['#ff9f43', '#ff5d5d'],
      ['#c084fc', '#f0abfc'], ['#a7f3d0', '#38bdf8'], ['#fff1a8', '#ff7043']
    ];
    // 铺满整屏：上到下、左到右都有，中间那几发更大
    var pts = [
      [0.16, 0.20, 0], [0.40, 0.13, 1], [0.64, 0.18, 2], [0.87, 0.24, 3],
      [0.26, 0.37, 4], [0.51, 0.29, 5], [0.75, 0.39, 0], [0.11, 0.51, 1],
      [0.36, 0.56, 2], [0.62, 0.50, 3], [0.89, 0.60, 4]
    ];
    var html = '';
    pts.forEach(function (p, bi) {
      var x = Math.round(W * p[0]), y = Math.round(H * p[1]);
      var c = palette[p[2] % palette.length];
      var big = (bi === 5 || bi === 2 || bi === 8);
      var rise = (0.48 + (bi % 3) * 0.05).toFixed(2);
      var d0 = (bi * 0.30).toFixed(2);
      var x0 = Math.round(x + (x - W / 2) * 0.28);
      html += '<span class="gf-shell" style="--x0:' + x0 + 'px; --x1:' + x + 'px; --y0:' + (H + 26) + 'px; --y1:' + y + 'px; --c:' + c[0] + '; --rise:' + rise + 's; --d:' + d0 + 's"></span>';
      var parts = '', n = big ? 18 : 15;
      for (var i = 0; i < n; i++) {
        var a = (Math.PI * 2 * i) / n + bi * 0.35;
        var r = (big ? 96 : 66) + (i % 3) * (big ? 32 : 26);
        parts += '<i style="--dx:' + Math.round(Math.cos(a) * r) + 'px; --dy:' + Math.round(Math.sin(a) * r) + 'px; --sz:' + (i % 4 === 0 ? 6 : 5) + 'px; --c:' + (i % 2 ? c[0] : c[1]) + '"></i>';
      }
      html += '<span class="gf-burst" style="left:' + x + 'px; top:' + y + 'px; --d:' + (Number(d0) + Number(rise) - 0.06).toFixed(2) + 's">' +
        parts + '<b class="gf-flash"></b></span>';
    });
    return '<div class="gf-fw">' + html + '</div>';
  }

  function openPlusFile(accept, camera) {
    var input = $('plusFile');
    input.value = '';
    input.accept = accept || '';
    if (camera) input.setAttribute('capture', 'environment'); else input.removeAttribute('capture');
    input.click();
  }

  function sendQuickText(text, withGeo) {
    if (!S.activeChat) return;
    sendText(text);
    toast('已发送');
  }

  function sendText(text) {
    if (!S.activeChat || !text) return;
    var clientId = 'c' + Date.now() + Math.random().toString(16).slice(2, 6);
    var payload = { type: 'send', chatId: S.activeChat, kind: 'text', content: text, clientId: clientId };
    var sent = false;
    if (socket && socket.readyState === 1) { try { socket.send(JSON.stringify(payload)); sent = true; } catch (e) { sent = false; } }
    if (!sent) api('/chats/' + encodeURIComponent(S.activeChat) + '/messages', { method: 'POST', body: JSON.stringify({ kind: 'text', content: text, clientId: clientId }) }).catch(function (e) { toast(e.message); });
  }

  function sendUploaded(kind, content) {
    if (!S.activeChat || !content) return '';
    var clientId = 'c' + Date.now() + Math.random().toString(16).slice(2, 6);
    var payload = { type: 'send', chatId: S.activeChat, kind: kind, content: content, clientId: clientId };
    var sent = false;
    if (socket && socket.readyState === 1) { try { socket.send(JSON.stringify(payload)); sent = true; } catch (e) { sent = false; } }
    if (!sent) api('/chats/' + encodeURIComponent(S.activeChat) + '/messages', { method: 'POST', body: JSON.stringify({ kind: kind, content: content, clientId: clientId }) }).catch(function (e) { toast(e.message); });
    return clientId;
  }

  /* 照片 / 拍摄 / 文件：先传到服务器，再把消息发出去 */
  /** 上传前压一下图片：长边最多 1600、JPEG 0.82（手机拍的大图能小好几倍） */
  function compressImage(file, maxSide, quality) {
    return new Promise(function (resolve) {
      if (!file || !/^image\//.test(file.type || '') || /gif|webp/i.test(file.type || '')) return resolve(file);
      var side = maxSide || 1600;
      if (file.size < 900 * 1024) return resolve(file);            // 本来就不大就别压了
      var reader = new FileReader();
      reader.onload = function () {
        var img = new Image();
        img.onload = function () {
          try {
            var w = img.naturalWidth, h = img.naturalHeight;
            var scale = Math.min(1, side / Math.max(w, h));
            var cw = Math.max(1, Math.round(w * scale)), ch = Math.max(1, Math.round(h * scale));
            var cv = document.createElement('canvas');
            cv.width = cw; cv.height = ch;
            cv.getContext('2d').drawImage(img, 0, 0, cw, ch);
            cv.toBlob(function (blob) {
              if (!blob) return resolve(file);
              var name = String(file.name || 'photo').replace(/\.[^.]+$/, '') + '.jpg';
              try { resolve(new File([blob], name, { type: 'image/jpeg' })); } catch (e) { resolve(blob); }
            }, 'image/jpeg', quality || 0.82);
          } catch (e) { resolve(file); }
        };
        img.onerror = function () { resolve(file); };
        img.src = String(reader.result);
      };
      reader.onerror = function () { resolve(file); };
      reader.readAsDataURL(file);
    });
  }

  function bindPlusFile() {
    $('plusFile').addEventListener('change', function (e) {
      var file = e.target.files && e.target.files[0];
      e.target.value = '';
      sendPickedFile(file);
    });
  }

  /** 把一张图/一个文件发到当前聊天里（相册直连和网页版 input 都走这里） */
  function sendPickedFile(file) {
      if (!file || !S.activeChat) return;
      if (file.size > 12 * 1024 * 1024) { toast('文件不能超过 12MB'); return; }
      var isImg = file.type.indexOf('image/') === 0;
      if (isImg) toast('正在处理图片…');
      compressImage(file).then(function (f2) {
        var reader = new FileReader();
        reader.onload = function () {
          api('/upload', { method: 'POST', body: JSON.stringify({ dataUrl: String(reader.result), filename: f2.name || file.name }) })
            .then(function (d) {
              if (isImg) sendUploaded('image', d.url);
              else sendUploaded('file', JSON.stringify({ url: d.url, name: d.name || file.name, bytes: d.bytes }));
            })
            .catch(function (err) { toast(err.message); });
        };
        reader.readAsDataURL(f2);
      });
  }

  /* ---------------------------------------------------------- 朋友圈 */
  function loadMomentsBadge() {
    /* 只要「有没有新朋友圈 + 最新一条的小图」，所以只取 1 条，请求很轻；
       这样就算定时刷也不会拖慢手机。 */
    api('/moments?limit=1').then(function (d) {
      S.moments = d.moments || [];
      var unread = d.unread != null ? d.unread : 0;
      /* 发现页「朋友圈」那一行右侧的小图：取最新一条朋友圈的第一张图（和微信一样）。
         有图时红点贴在图的右上角；没有图时红点还是回到行尾。 */
      var latest = (S.moments || [])[0] || null;
      var img = (latest && latest.images && latest.images.length) ? latest.images[0] : '';
      /* 最新那条没有配图时，用「发圈那个人的头像」来显示——微信这一行就是
         「小图/头像 + 右上角红点」，不能只剩一个孤零零的红点。 */
      if (!img && latest && latest.author && latest.author.avatar) img = latest.author.avatar;
      var thumb = $('momentThumb');
      if (thumb) {
        thumb.hidden = !img;
        var im = $('momentThumbImg');
        if (im) { if (img) im.src = img; else im.removeAttribute('src'); }
      }
      var tdot = $('momentThumbDot');
      if (tdot) tdot.hidden = !(img && unread);
      $('momentBadge').hidden = !unread || !!img;
      setTabBadge('tabBadgeMoments', unread, true);
    }).catch(function () { });
  }

  /* ---------------- 发现页（后台可以自由增删改） ---------------- */
  /* 朋友圈单图：按原图比例显示（比例限制在 3:4 ~ 2:1，超出的居中裁切） */
  window.mmFitSingle = function (img) {
    try {
      if (!img.naturalWidth || !img.naturalHeight) return;
      var box = img.parentElement ? img.parentElement.clientWidth : img.naturalWidth;
      var a = img.naturalWidth / img.naturalHeight;
      a = Math.min(2, Math.max(0.75, a));
      /* 微信的规矩：横图可以占满内容宽度，竖图只占 62%（不然一张竖图糊满屏太大） */
      var limit = a >= 1 ? box : box * 0.62;
      var w = Math.min(img.naturalWidth, limit);        // 小图不放大
      img.style.width = w + 'px';
      img.style.aspectRatio = String(a);
      img.style.objectFit = 'cover';
    } catch (e) { }
  };

  /* 单图按原图比例显示：插入 DOM 之后再绑事件（不用内联 onload，配合 CSP 更安全） */
  window.mmFitIn = function (root) {
    try {
      var box = root || document;
      [].slice.call(box.querySelectorAll('img[data-img]')).forEach(function (im) {
        if (im.dataset.mmFit) return;
        im.dataset.mmFit = '1';
        if (im.complete && im.naturalWidth) window.mmFitSingle(im);
        else im.addEventListener('load', function () { window.mmFitSingle(im); });
      });
    } catch (e) { }
  };

  function paintDiscover() {
    var box = $('discoverList');
    if (!box) return;
    var items = (S.discover || []).filter(function (i) { return i.enabled !== false; });
    if (!items.length) { box.innerHTML = ''; return; }
    var html = '', group = null;
    items.forEach(function (it, idx) {
      var isMoments = it.action === 'moments';
      if (group === null) html += '<div class="me-block me-rows">';
      else if (it.group !== group) html += '</div><div class="me-gap"></div><div class="me-block me-rows">';
      group = it.group;
      html += '<button class="me-row" data-dsc="' + idx + '"' + (isMoments ? ' id="cellMoments"' : '') + '>' +
        '<span class="me-ico" style="color:' + esc(it.color || '#4A90D9') + '">' + (it.svg || '') + '</span>' +
        '<span class="me-label">' + esc(it.label) + '</span>' +
        (isMoments
          ? '<span class="me-thumb" id="momentThumb" hidden><img id="momentThumbImg" alt="">' +
            '<span class="me-thumb-dot" id="momentThumbDot" hidden></span></span>' +
            '<span class="me-dot" id="momentBadge" hidden></span>'
          : '') +
        '<span class="me-arrow">›</span></button>';
    });
    html += '</div>';
    box.innerHTML = html;
  }

  /* ---------------- 后台「界面文字」里配的：A-Z 索引的字号/颜色/行距 ---------------- */
  var UI_CFG = null;
  /* 把配置写进 CSS 变量（不发请求，切深浅色时可以随时重放） */
  function applyUiVars() {
    var ui = UI_CFG;
    if (!ui) return;
    (function () {
      var root = document.documentElement;
      /* 手机顶部那条（状态栏/浏览器顶栏）的颜色跟着页面底色走，别用微信绿 */
      try {
        var meta = document.getElementById('themeColorMeta');
        if (meta) {
          var dark = document.documentElement.getAttribute('data-theme') === 'dark';
          var raw = ui.pageBg || '';
          var pair = String(raw).split('|');
          var color = dark ? (pair[1] || pair[0] || '#0B0B0D') : (pair[0] || '#EDEDED');
          meta.setAttribute('content', color.trim());
        }
      } catch (e) { }
      if (ui.navTitle) root.style.setProperty('--nav-title-size', Number(ui.navTitle) + 'px');
      if (ui.navTitleWeight) root.style.setProperty('--nav-title-weight', String(ui.navTitleWeight));
      if (ui.chatNavBg) {
        var cp = String(ui.chatNavBg).split('|');
        var darkNow = document.documentElement.getAttribute('data-theme') === 'dark';
        var navColor = (darkNow ? (cp[1] || cp[0]) : cp[0]).trim();
        root.style.setProperty('--chat-nav-bg', navColor);
        /* 毛玻璃那层用后台配的颜色（浅色再往白里调一半）＋ 后台调的玻璃不透明度，
           所以「顶栏颜色」和「毛玻璃不透明度」两个都能在后台改 */
        var m6 = /^#([0-9a-f]{6})$/i.exec(navColor);
        if (m6) {
          var v = parseInt(m6[1], 16);
          var r0 = (v >> 16) & 255, g0 = (v >> 8) & 255, b0 = v & 255;
          if (!darkNow) { r0 = Math.round(r0 + (255 - r0) * 0.5); g0 = Math.round(g0 + (255 - g0) * 0.5); b0 = Math.round(b0 + (255 - b0) * 0.5); }
          var ga = Number(ui.glassAlpha);
          if (!isFinite(ga) || ga <= 0) ga = 0.8;
          ga = Math.min(1, Math.max(0.2, ga));
          root.style.setProperty('--glass-nav-bg', 'rgba(' + r0 + ',' + g0 + ',' + b0 + ', ' + ga + ')');
        }
      }
      /* 后台那格「聊天页毛玻璃不透明度」：越小颜色越透出来，越大越白 */
      if (ui.glassAlpha) {
        var gv = Number(ui.glassAlpha);
        if (isFinite(gv) && gv > 0) root.style.setProperty('--glass-alpha', String(Math.min(1, Math.max(0.2, gv))));
      }
      if (ui.ctIdxSize) root.style.setProperty('--ct-idx-size', Number(ui.ctIdxSize) + 'px');
      if (ui.ctIdxColor) {
        var parts = String(ui.ctIdxColor).split('|');
        var light = (parts[0] || '').trim();
        var dark = (parts[1] || light).trim();
        var darkOn = document.documentElement.getAttribute('data-theme') === 'dark';
        root.style.setProperty('--ct-idx-color', darkOn ? dark : light);
      }
      if (ui.ctIdxItemH) {
        var h = Number(ui.ctIdxItemH);
        var st = document.getElementById('__ctIdxStyle');
        if (!st) { st = document.createElement('style'); st.id = '__ctIdxStyle'; document.head.appendChild(st); }
        /* 每个字母占多高 = 行距。原来写成 .ct-idx .ct-idx（自己套自己）根本选不中，
           所以后台调「A-Z 行距」一直没反应。 */
        st.textContent = '.ct-index .ct-idx{height:' + h + 'px;display:flex;align-items:center;justify-content:center}'
          + '.ct-index{gap:0}';
      }
      /* 聊天里那行时间的小框（后台「界面文字」里配）：圆角/留白/底色/文字色 */
      (function () {
        var root2 = document.documentElement;
        if (ui.chatTimeRadius !== undefined && ui.chatTimeRadius !== '') root2.style.setProperty('--chat-time-radius', Number(ui.chatTimeRadius) + 'px');
        if (ui.chatTimePadX !== undefined && ui.chatTimePadX !== '') root2.style.setProperty('--chat-time-padx', Number(ui.chatTimePadX) + 'px');
        if (ui.chatTimePadY !== undefined && ui.chatTimePadY !== '') root2.style.setProperty('--chat-time-pady', Number(ui.chatTimePadY) + 'px');
        var dark2 = root2.getAttribute('data-theme') === 'dark';
        if (ui.chatTimeBg) {
          var bp = String(ui.chatTimeBg).split('|');
          root2.style.setProperty('--chat-time-bg', (dark2 ? (bp[1] || bp[0]) : bp[0]).trim());
        }
        if (ui.chatTimeColor) {
          var cp2 = String(ui.chatTimeColor).split('|');
          root2.style.setProperty('--chat-time-color', (dark2 ? (cp2[1] || cp2[0]) : cp2[0]).trim());
        }
      })();
    })();
  }
  function applyUiCss() {
    return api('/ui').then(function (d) {
      UI_CFG = (d && d.ui) || {};
      applyUiVars();
      applyTabIcons((d && d.icons) || {});     // 底栏那 4 个图标也能被后台换掉
    }).catch(function () { });
  }

  /* 底栏 4 个图标（微信/通讯录/发现/我）：后台「UI 图标 → 底栏图标」里换过就用换过的。
     以前网页版这里是写死在 HTML 里的，所以后台换了没反应。 */
  var TAB_ICON_KEYS = ['tab.chat', 'tab.contacts', 'tab.discover', 'tab.me'];
  function applyTabIcons(icons) {
    try {
      var tabs = document.querySelectorAll('.wx-tab');
      TAB_ICON_KEYS.forEach(function (key, i) {
        var v = icons && icons[key];
        var tab = tabs[i];
        if (!tab || !v) return;
        var html;
        if (v.indexOf('<svg') === 0) html = v;
        else if (/^(https?:|\/uploads|data:)/.test(v)) html = '<img src="' + esc(v) + '" alt="" style="width:100%;height:100%;object-fit:contain">';
        else html = '<span style="font-size:22px;line-height:1">' + esc(v) + '</span>';
        var boxes = tab.querySelectorAll('.wt-ico');
        Array.prototype.forEach.call(boxes, function (box) { box.innerHTML = html; });
      });
    } catch (e) { }
  }

  /* ---------------- 我页下面的行（后台可自由增删改） ---------------- */
  function paintMePage() {
    var box = $('meList');
    if (!box) return;
    var items = (S.mePage || []).filter(function (i) { return i.enabled !== false; });
    var html = '', group = null;
    items.forEach(function (it, idx) {
      if (group === null) html += '<div class="me-block me-rows">';
      else if (it.group !== group) html += '</div><div class="me-gap"></div><div class="me-block me-rows">';
      group = it.group;
      html += '<button class="me-row" data-me="' + idx + '">' +
        '<span class="me-ico" style="color:' + esc(it.color || '#4A90D9') + '">' + (it.svg || '') + '</span>' +
        '<span class="me-label">' + esc(it.label) + '</span>' +
        '<span class="me-arrow">›</span></button>';
    });
    if (items.length) html += '</div><div class="me-gap"></div>';
    box.innerHTML = html;
  }

  function loadMePage() {
    return api('/me-page').then(function (d) {
      S.mePage = d.items || [];
      paintMePage();
    }).catch(function () { });
  }

  /* 进 App / 切到发现页都拉一次：后台改了立刻能看到 */
  function loadDiscover() {
    return api('/discover').then(function (d) {
      S.discover = d.items || [];
      paintDiscover();
      loadMomentsBadge();          // 朋友圈那行的小图 + 红点
    }).catch(function () { });
  }

  /* ---------------- 服务页（我 → 服务）
     整页由后台「服务页」模块下发（/api/service）：一张绿卡 + 几张白卡，
     每张白卡 = 分类标题 + 四列图标格。尺寸照参考图量的（8pt 边距 / 卡片间距 8pt /
     绿卡 144pt / 白卡 = 标题 48 + 每行 93 + 底 19 / 圆角 7）。 */
  function paintService() {
    var box = $('svcList');
    if (!box) return;
    var cfg = S.service || {};
    var card = cfg.card || {};
    if ($('svcTitle')) $('svcTitle').textContent = cfg.title || '服务';

    /* 样式（后台「服务页 → 样式」里配的）：绿卡背景、图标大小、各处字体大小和颜色。
       数字改了以后卡片的行高会跟着长，不会把字挤出去。 */
    var st = cfg.style || {};
    var icon = Number(st.iconSize) || 28;
    var nameSize = Number(st.cardTextSize) || 18;
    var subSize = Number(st.cardSubSize) || 12;
    var gridTitleSize = Number(st.gridTitleSize) || 14;
    var gridTextSize = Number(st.gridTextSize) || 13;
    var subOp = (st.cardSubOpacity === undefined || st.cardSubOpacity === null || st.cardSubOpacity === '') ? 0.5 : Number(st.cardSubOpacity);
    if (!isFinite(subOp)) subOp = 0.5;
    box.style.setProperty('--sv-icon', icon + 'px');
    box.style.setProperty('--sv-cell-h', (92 + (icon - 28) + (gridTextSize - 13)) + 'px');
    box.style.setProperty('--sv-title-h', (48 + (gridTitleSize - 14)) + 'px');
    box.style.setProperty('--sv-title-size', gridTitleSize + 'px');
    box.style.setProperty('--sv-text-size', gridTextSize + 'px');
    /* 颜色留空 / 还是默认值时，不写死变量 —— 让它跟主题走（浅色深灰、深色浅灰） */
    if (st.gridTitleColor && String(st.gridTitleColor).toUpperCase() !== '#7A7A7A') {
      box.style.setProperty('--sv-title-color', st.gridTitleColor);
    } else {
      box.style.removeProperty('--sv-title-color');
    }
    if (st.gridTextColor) box.style.setProperty('--sv-text-color', st.gridTextColor);
    else box.style.removeProperty('--sv-text-color');
    box.style.setProperty('--sv-card-h', (144 + (icon - 28) + (nameSize - 18) + (subSize - 12)) + 'px');
    box.style.setProperty('--sv-card-color', st.cardTextColor || '#FFFFFF');
    box.style.setProperty('--sv-card-name-size', nameSize + 'px');
    box.style.setProperty('--sv-card-sub-size', subSize + 'px');
    box.style.setProperty('--sv-card-sub-op', String(subOp));
    if (st.curSize) box.style.setProperty('--cur-size', st.curSize + 'px');
    else box.style.removeProperty('--cur-size');

    var html = '';
    if (card.enabled !== false) {
      var left = card.left || {}, right = card.right || {};
      /* 绿卡右边的零钱：后台开了「金额打星号」就显示 ¥****（点进钱包页可以点开看） */
      var serviceMask = st.maskAmount !== false;      // 默认打星号，后台可以关
      var rsub = right.sub || (serviceMask ? '¥****' : ('¥' + (Number(balanceOf()) || 0).toFixed(2)));
      var cardImg = st.cardImage ? ('url("' + String(st.cardImage).replace(/["()]/g, '') + '")') : 'none';
      var half = function (h, sub, act) {
        return '<button class="sv-half" data-svc="card" data-act="' + esc(act) + '">' +
          '<span class="sv-ico">' + iconHtml(h.svg) + '</span>' +
          '<span class="sv-name">' + esc(h.label || '') + '</span>' +
          (sub ? '<span class="sv-sub">' + moneyHtml(sub) + '</span>' : '') +
          '</button>';
      };
      html += '<div class="sv-card" style="background-color:' + esc(card.bg || '#2AAE67')
        + ';background-image:' + esc(cardImg) + '">'
        + half(left, left.sub || '', left.action || 'pay')
        + half(right, rsub, right.action || 'wallet')
        + '</div>';
    }
    (cfg.groups || []).forEach(function (g, gi) {
      var items = g.items || [];
      if (!items.length) return;
      /* 版块自己的上下尺寸（后台「版块上下/行距」里配的；留空用全局）。
         左右固定 8px，不给调。 */
      var gs = g.style || {};
      var bst = '';
      if (gs.gapTop !== null && gs.gapTop !== undefined) bst += '--sv-gap-top:' + gs.gapTop + 'px;';
      if (gs.gapBottom !== null && gs.gapBottom !== undefined) bst += '--sv-gap-bottom:' + gs.gapBottom + 'px;';
      html += '<div class="sv-block"' + (bst ? ' style="' + bst + '"' : '') + '>'
        + '<div class="sv-title">' + esc(g.title || '') + '</div>'
        + '<div class="sv-grid">'
        + items.map(function (it, i) {
          return '<button class="sv-cell" data-svc="item" data-g="' + gi + '" data-i="' + i + '">' +
            '<span class="sv-ico" style="color:' + esc(it.color || '#1180E0') + '">' + iconHtml(it.svg) + '</span>' +
            '<span class="sv-label">' + esc(it.label || '') + '</span></button>';
        }).join('')
        + '</div></div>';
    });
    box.innerHTML = html;
  }

  function loadService() {
    return api('/service').then(function (d) {
      S.service = d || {};
      paintService();
      return d;
    }).catch(function () { });
  }

  function openServicePage() {
    $('serviceScreen').hidden = false;
    loadBalance();
    return loadService();
  }

  /* 绿卡右边「钱包」：先看零钱，再点一下刷新 */
  function openWallet() {
    loadBalance();
    sheet([
      {
        label: '零钱余额 ' + money(balanceOf()) + '（点一下刷新）',
        run: function () {
          loadBalance().then(function () { toast('零钱 ' + money(balanceOf())); });
        }
      },
      { label: '账单：进任意聊天看「转账」记录', run: function () { toast('账单在聊天里的转账消息上'); } }
    ]);
  }

  /* 点格子：绿卡两半按 action 走，格子的 action 里 pay/wallet 也能用，其余先占位 */
  function runServiceAction(act, label) {
    if (act === 'wallet') { openWalletPage(); return; }
    if (act === 'pay') { toast('收付款：还没接后端，先把页面做出来'); return; }
    toast((label || '这个') + '：还没接后端，先把页面做出来');
  }

  /* ---------------- 钱包页（我 → 服务 → 钱包）
     整页由后台「钱包页」模块下发（/api/wallet）：两张全宽白卡 + 底部两个链接。
     尺寸照参考图量的（行高 56.6 / 图标 20 / 文字 x=56.7 / 分隔线缩进 56）。 */
  var WA_ARROW = '<span class="wa-arrow"><svg viewBox="0 0 8 14" width="7.3" height="12.7" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M1.5 1.3l5 5.7-5 5.7"/></svg></span>';

  /* 金额打星号：¥122.00 → ¥****（后台能关，点一下能看） */
  /* 图标：可能是内置的 svg，也可能是后台传上来的一张图片（/uploads/xxx.png） */
  /* 金额里的「¥」包一层：后台给「¥ 符号字号」时它就会比数字小（微信那样） */
  function moneyHtml(text) {
    return amtHtml(text, true);
  }
  /* 金额渲染：withCur = false 时只把方形小数点做出来，不带 ¥（账单页参考图就是只显示 +/− 和数字） */
  function amtHtml(text, withCur) {
    var s = String(text == null ? '' : text);
    if (!s) return s;
    var out = esc(s);
    if (withCur !== false) out = out.replace(/¥/g, '<span class="cur">¥</span>');
    return out.replace(/\./g, '<i class="dot"></i>');
  }
  function iconHtml(v) {
    var s = String(v == null ? '' : v);
    if (!s) return '';
    if (/^(https?:|\/uploads|data:)/.test(s)) return '<img src="' + esc(s) + '" alt="">';
    return s;
  }
  function maskMoney(text) {
    var s = String(text == null ? '' : text);
    if (!s) return s;
    if (s.indexOf('¥') >= 0) return '¥****';
    return s.replace(/[0-9]/g, '*');
  }
  function walletMasked(it, cfg) {
    var globalOn = !cfg || !cfg.style || cfg.style.maskAmount !== false;
    var rowOn = !it || it.mask === undefined || it.mask !== false;
    return globalOn && rowOn;
  }

  function paintWallet() {
    var box = $('waList');
    if (!box) return;
    var cfg = S.wallet || {};
    var st = cfg.style || {};
    if ($('waTitle')) $('waTitle').textContent = cfg.title || '钱包';
    if ($('waRight')) {
      var r = cfg.right || {};
      $('waRight').textContent = r.label || '账单';
      $('waRight').hidden = !(r.label || '');
    }
    /* 尺寸/颜色都做成 CSS 变量，后台改完立刻生效 */
    var set = function (name, v) { if (v === undefined || v === null || v === '') box.style.removeProperty(name); else box.style.setProperty(name, v); };
    set('--wa-row', st.rowHeight ? st.rowHeight + 'px' : '');
    set('--wa-icon', st.iconSize ? st.iconSize + 'px' : '');
    set('--wa-icon-left', (st.iconLeft === undefined || st.iconLeft === null || st.iconLeft === '') ? '' : st.iconLeft + 'px');
    set('--wa-text-left', st.textLeft ? st.textLeft + 'px' : '');
    set('--wa-right', (st.rightInset === undefined) ? '' : st.rightInset + 'px');
    set('--wa-label-size', st.labelSize ? st.labelSize + 'px' : '');
    set('--wa-value-size', st.valueSize ? st.valueSize + 'px' : '');
    set('--wa-note-size', st.noteSize ? st.noteSize + 'px' : '');
    set('--wa-footer-size', st.footerSize ? st.footerSize + 'px' : '');
    set('--wa-gap', st.groupGap !== undefined ? st.groupGap + 'px' : '');
    set('--wa-divider', st.dividerInset !== undefined ? st.dividerInset + 'px' : '');
    set('--wa-label-color', st.labelColor || '');
    set('--wa-note-color', st.noteColor || '');
    set('--wa-footer-color', st.footerColor || '');
    if (st.valueColor && String(st.valueColor).toUpperCase() !== '#1A1A1A') set('--wa-value-color', st.valueColor);
    else set('--wa-value-color', '');
    if (st.curSize) set('--cur-size', st.curSize + 'px'); else set('--cur-size', '');

    var html = '';
    (cfg.groups || []).forEach(function (g, gi) {
      var items = g.items || [];
      if (!items.length) return;
      html += '<div class="wa-block">';
      items.forEach(function (it, i) {
        var shown = it.value || '';
        var canMask = shown && walletMasked(it, cfg);
        var allowReveal = !cfg.style || cfg.style.maskReveal !== false;
        if (canMask && !(S.walletShown || {})[it.id]) shown = maskMoney(shown);
        html += '<button class="wa-row" data-wa="item" data-g="' + gi + '" data-i="' + i + '">' +
          '<span class="wa-ico" style="color:' + esc(it.color || '#1180E0') + '">' + iconHtml(it.svg) + '</span>' +
          '<span class="wa-label">' + esc(it.label || '') + '</span>' +
          (it.note ? '<span class="wa-note">' + esc(it.note) + '</span>' : '') +
          (shown ? '<span class="wa-value"' + (canMask && allowReveal ? ' data-mask="1" data-id="' + esc(it.id) + '"' : '') + '>'
            + moneyHtml(shown) + (canMask && allowReveal ? ' <em class="wa-eye">' + ((S.walletShown || {})[it.id] ? '隐藏' : '显示') + '</em>' : '')
            + '</span>' : '') +
          WA_ARROW +
          '</button>';
        if (i < items.length - 1) html += '<div class="wa-sep"></div>';
      });
      html += '</div>';
    });
    box.innerHTML = html;

    var foot = $('waFoot');
    foot.innerHTML = (cfg.footer || []).map(function (f, i) {
      if (f.enabled === false) return '';
      return '<button data-wa="foot" data-i="' + i + '">' + esc(f.label || '') + '</button>';
    }).join('');
  }

  function loadWallet() {
    return api('/wallet').then(function (d) {
      S.wallet = d || {};
      paintWallet();
      return d;
    }).catch(function () { });
  }

  function openWalletPage() {
    $('walletScreen').hidden = false;
    S.walletShown = {};        // 每次进来金额都先藏着
    return loadWallet();
  }

  function runWalletAction(act, label) {
    if (act === 'balance') { openCoinPage(); return; }
    if (act === 'bills') { openBillList(); return; }
    if (act === 'service') { sheet([{ label: '客服中心：暂时没有在线客服', run: function () { } }]); return; }
    if (act === 'settings') { openSettingsPage(); return; }
    if (act === 'identity') { toast('身份信息：还没接后端，先把页面做出来'); return; }
    toast((label || '这个') + '：还没接后端，先把页面做出来');
  }

  /* ---------------- 账单页（钱包页右上角「账单」进来）
     数据来自 /api/bills：这个人的所有转账（进出方向 / 对方 / 状态 / 时间），按月分组。 */
  function billStateText(b) {
    if (b.direction === 'out') {
      if (b.status === 'received') return '对方已收款';
      if (b.status === 'refunded') return '已退回';
      return '待对方收款';
    }
    if (b.status === 'received') return '已收款';
    if (b.status === 'refunded') return '已退回';
    return '待收款';
  }

  function paintBills() {
    var box = $('bllList');
    if (!box) return;
    var d = S.billsData || {};
    var all = d.bills || [];
    var f = S.billFilter || 'all';
    var q = String(S.billQuery || '').trim().toLowerCase();
    var list = all.filter(function (b) {
      if (f === 'out' && b.direction !== 'out') return false;
      if (f === 'in' && b.direction !== 'in') return false;
      if (q) {
        var hay = ((b.peerName || '') + ' ' + (b.note || '')).toLowerCase();
        if (hay.indexOf(q) < 0) return false;
      }
      return true;
    });
    if ($('bllFilterText')) {
      $('bllFilterText').textContent = f === 'out' ? '只看支出' : (f === 'in' ? '只看收入' : '全部账单');
    }
    var monthSum = function (m) {
      var out = 0;
      var inc = 0;
      all.forEach(function (b) {
        if (String(b.createdAt || '').slice(0, 7) !== m) return;
        if (b.direction === 'out') out += Number(b.amount) || 0;
        else if (b.status === 'received') inc += Number(b.amount) || 0;
      });
      return { out: out, in: inc };
    };
    var html = '';
    /* 账单页的图标大小/字号/行高（后台「账单页」里配的） */
    var bs = d.style || {};
    var setB = function (k, v) { if (v === undefined || v === null || v === '') box.style.removeProperty(k); else box.style.setProperty(k, v); };
    setB('--bll-icon', bs.iconSize ? bs.iconSize + 'px' : '');
    setB('--bll-title-size', bs.titleSize ? bs.titleSize + 'px' : '');
    setB('--bll-time-size', bs.timeSize ? bs.timeSize + 'px' : '');
    setB('--bll-amt-size', bs.amountSize ? bs.amountSize + 'px' : '');
    setB('--bll-month-size', bs.monthSize ? bs.monthSize + 'px' : '');
    setB('--bll-sum-size', bs.sumSize ? bs.sumSize + 'px' : '');
    setB('--bll-row-h', bs.rowHeight ? bs.rowHeight + 'px' : '');
    setB('--cur-size', bs.curSize ? bs.curSize + 'px' : '');
    setB('--bll-amt-weight', bs.amountWeight ? String(bs.amountWeight) : '');
    if (!list.length) {
      html = '<div class="bll-empty">还没有账单</div>';
    } else {
      var cur = null;
      var open = false;
      list.forEach(function (b) {
        var m = String(b.createdAt || '').slice(0, 7);
        if (m !== cur) {
          if (open) html += '</div>';
          var s = monthSum(m);
          html += '<div class="bll-month">'
            + '<button class="bll-month-name" data-monthpick="1">'
            + esc(m ? (m.slice(0, 4) + '年' + Number(m.slice(5, 7)) + '月') : '更早')
            + '<svg viewBox="0 0 12 12" width="9" height="9" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M2.4 4.4L6 8l3.6-3.6"/></svg>'
            + '</button>'
            + '<span class="bll-month-sum">支出 ' + money(s.out) + ' 收入 ' + money(s.in) + '</span>'
            + '</div><div class="bll-card">';
          open = true;
          cur = m;
        }
        var mine = b.direction === 'out';
        var face = b.peerAvatar
          ? '<img src="' + esc(b.peerAvatar) + '" alt="" decoding="async">'
          : esc(String(b.peerName || '?').trim().slice(0, 1));
        html += '<button class="bll-row" data-bill="' + esc(b.id) + '">'
          + '<span class="bll-face">' + face + '</span>'
          + '<span class="bll-mid">'
          + '<span class="bll-name">' + esc(b.peerName || '好友') + '</span>'
          + '<span class="bll-sub">' + esc(fmtBillTime(b.createdAt)) + '</span></span>'
          + '<span class="bll-amt' + (mine ? '' : ' is-in') + '">'
          /* 收入不带 +，只有支出带 -（跟参考图一致） */
          + amtHtml((mine ? '-' : '') + ((bs.showCur === true)
              ? money(b.amount)
              : (Number(b.amount) || 0).toFixed(2)), bs.showCur === true)
          + '</span>'
          + '</button>';
      });
      if (open) html += '</div>';
    }
    box.innerHTML = html;
  }

  function loadBillsPage(month) {
    var q = month ? ('?month=' + encodeURIComponent(month)) : '';
    return api('/bills' + q).then(function (d) {
      S.billsData = d || {};
      S.billById = {};
      (d.bills || []).forEach(function (b) { S.billById[b.id] = b; });
      paintBills();
      return d;
    }).catch(function (e) { toast(e.message || '账单读取失败'); });
  }

  function openBillList() {
    $('billListScreen').hidden = false;
    S.billFilter = 'all';
    S.billQuery = '';
    if ($('bllQuery')) $('bllQuery').value = '';
    return loadBillsPage('');
  }

  /* ---------------- 零钱页（钱包页点「零钱」进来）
     文案/按钮/链接/样式都是后台「零钱页」模块配的（/api/balance-page），余额是真的。 */
  function paintCoin() {
    var d = S.coinPage || {};
    var st = d.style || {};
    var box = $('coinScroll');
    if (box) {
      var set = function (k, v) { if (v === undefined || v === null || v === '') box.style.removeProperty(k); else box.style.setProperty(k, v); };
      set('--coin-bg', st.bg || '');
      set('--coin-circle', st.circleSize ? st.circleSize + 'px' : '');
      set('--coin-circle-color', st.circleColor || '');
      set('--coin-yen-size', st.yenSize ? st.yenSize + 'px' : '');
      set('--coin-yen-color', st.yenColor || '');
      set('--coin-pad-top', st.padTop !== undefined && st.padTop !== null ? st.padTop + 'px' : '');
      set('--coin-gap-title', st.gapTitle !== undefined && st.gapTitle !== null ? st.gapTitle + 'px' : '');
      set('--coin-gap-amount', st.gapAmount !== undefined && st.gapAmount !== null ? st.gapAmount + 'px' : '');
      set('--coin-gap-note', st.gapNote !== undefined && st.gapNote !== null ? st.gapNote + 'px' : '');
      set('--coin-title-size', st.titleSize ? st.titleSize + 'px' : '');
      set('--coin-amount-size', st.amountSize ? st.amountSize + 'px' : '');
      set('--coin-note-size', st.noteSize ? st.noteSize + 'px' : '');
      set('--coin-note-color', st.noteColor || '');
      set('--coin-btn-w', st.btnWidth ? st.btnWidth + 'px' : '');
      set('--coin-btn-h', st.btnHeight ? st.btnHeight + 'px' : '');
      set('--coin-btn-r', st.btnRadius !== undefined ? st.btnRadius + 'px' : '');
      set('--coin-recharge-bg', st.rechargeBg || '');
      set('--coin-recharge-ink', st.rechargeInk || '');
      set('--coin-withdraw-bg', st.withdrawBg || '');
      set('--coin-withdraw-ink', st.withdrawInk || '');
      set('--coin-link-size', st.linkSize ? st.linkSize + 'px' : '');
      set('--coin-link-color', st.linkColor || '');
      set('--coin-foot-size', st.footerSize ? st.footerSize + 'px' : '');
      set('--coin-foot-color', st.footerColor || '');
    }
    if ($('coinNavTitle')) $('coinNavTitle').textContent = d.navTitle || '零钱明细';
    if ($('coinTitle')) $('coinTitle').textContent = d.title || '我的零钱';
    if ($('coinAmount')) $('coinAmount').innerHTML = moneyHtml(money(d.balance || 0));
    if (box) {
      if (st.curSize) box.style.setProperty('--cur-size', st.curSize + 'px');
      else box.style.removeProperty('--cur-size');
    }
    var note = $('coinNote');
    if (note) {
      note.hidden = !d.note;
      note.innerHTML = d.note ? (esc(d.note) + '<svg viewBox="0 0 8 14" width="6.4" height="11" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M1.5 1.3l5 5.7-5 5.7"/></svg>') : '';
    }
    if ($('coinRecharge')) $('coinRecharge').textContent = (d.recharge || {}).label || '充值';
    if ($('coinWithdraw')) $('coinWithdraw').textContent = (d.withdraw || {}).label || '提现';
    if ($('coinLinks')) {
      $('coinLinks').innerHTML = (d.links || []).filter(function (x) { return x.enabled !== false; })
        .map(function (x, i) { return '<button data-coinlink="' + i + '">' + esc(x.label) + '</button>'; }).join('');
    }
    if ($('coinFoot')) $('coinFoot').textContent = d.footer || '';
  }

  function loadCoinPage() {
    return api('/balance-page').then(function (d) {
      S.coinPage = d || {};
      paintCoin();
      return d;
    }).catch(function (e) { toast(e.message || '零钱读取失败'); });
  }

  function openCoinPage() {
    $('coinScreen').hidden = false;
    return loadCoinPage();
  }

  function runCoinAction(act, label) {
    if (act === 'recharge') { openRechargeSheet(); return; }
    if (act === 'bills') { openBillList(); return; }
    if (act === 'faq') { openFaqSheet(); return; }
    if (act === 'withdraw') { toast('提现：还没接后端，先把页面做出来'); return; }
    toast((label || '这个') + '：还没接后端，先把页面做出来');
  }

  /* 常见问题：后台「零钱页」里配的问答（点问题看答案） */
  function openFaqSheet() {
    var list = ((S.coinPage || {}).faq) || [];
    if (!list.length) { toast('还没有常见问题'); return; }
    sheet(list.map(function (it) {
      return {
        label: it.q,
        run: function () { sheet([{ label: it.a, run: function () { } }]); }
      };
    }));
  }

  /* 账单导出 CSV（点「⋯ → 导出账单」） */
  /* 账单常见问题（后台「账单页 → 常见问题」里配的问答） */
  function openBillsFaq() {
    var list = ((S.billsData || {}).faq) || [];
    if (!list.length) { toast('还没有常见问题'); return; }
    sheet(list.map(function (it) {
      return {
        label: it.q,
        run: function () { sheet([{ label: it.a, run: function () { } }]); }
      };
    }));
  }
  function exportBillsCsv() {
    var list = ((S.billsData || {}).bills) || [];
    if (!list.length) { toast('还没有账单可以导出'); return; }
    var rows = [['时间', '对方', '方向', '金额', '状态', '说明', '支付方式', '单号']];
    list.forEach(function (b) {
      rows.push([
        fmtBillTime(b.createdAt),
        b.peerName || '',
        b.direction === 'out' ? '支出' : '收入',
        (b.direction === 'out' ? '-' : '+') + (Number(b.amount) || 0).toFixed(2),
        billStateText(b),
        b.note || '',
        b.method === 'card' ? '银行卡' : '零钱',
        b.id || ''
      ]);
    });
    var csv = '\ufeff' + rows.map(function (r) {
      return r.map(function (c) { return '"' + String(c).replace(/"/g, '""') + '"'; }).join(',');
    }).join('\r\n');
    try {
      var blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
      var a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = '账单-' + new Date().toISOString().slice(0, 10) + '.csv';
      document.body.appendChild(a);
      a.click();
      setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 800);
      toast('账单已导出（' + list.length + ' 笔）');
    } catch (e) {
      toast('导出失败：可以长按复制');
    }
  }

  function openMoments(userId) {
    $('momentsScreen').hidden = false;
    S.momentsUser = userId || null;
    /* 看别人的朋友圈时，右上角那个「相机」不显示（微信就是这样） */
    if ($('momentsCamera')) $('momentsCamera').hidden = !!userId;
    return loadMoments();
  }

  /* 拉一次朋友圈（自己发完、换完封面也走这里刷新） */
  function loadMoments() {
    var url = '/moments?limit=30' + (S.momentsUser ? '&userId=' + encodeURIComponent(S.momentsUser) : '');
    return api(url).then(function (d) {
      S.moments = d.moments || [];
      S.momentsMore = !!d.hasMore;
      S.momentsTotal = d.total || S.moments.length;
      S.momentsTarget = d.target || null;      // 看别人的朋友圈时，封面用他的
      renderMoments();
      applyCover();
      api('/moments/seen', { method: 'POST' }).catch(function () { });
      $('momentBadge').hidden = true;
      setTabBadge('tabBadgeMoments', 0, true);
    }).catch(function (e) { toast(e.message); });
  }

  /* 封面：自己设了就用自己的图，没设就用默认渐变 */
  /* 滑过封面 → 顶部标题栏出现「朋友圈」（微信就是这样） */
  function syncMomentsTitle() {
    var sc = $('momentsScroll');
    var nav = document.querySelector('#momentsScreen .wx-nav');
    var cover = $('momentsCover');
    if (!sc || !nav || !cover) return;
    var base = Number(cover.dataset.baseH) || cover.getBoundingClientRect().height || 240;
    var solid = sc.scrollTop > base - 52;
    nav.classList.toggle('is-solid', solid);
    $('momentsTitle').textContent = solid ? '朋友圈' : '';
  }

  function applyCover() {
    var cover = $('momentsCover');
    if (!cover) return;
    /* 看别人的朋友圈 → 用他的封面；看自己的 → 用我的封面 */
    var who = (S.momentsUser && S.momentsTarget) ? S.momentsTarget : (S.me || {});
    var src = who.momentCover || '';
    cover.style.backgroundImage = src ? 'url("' + src + '")' : '';
    // 长封面可以选显示上部 / 中间 / 下部
    var pos = who.momentCoverPos != null ? Number(who.momentCoverPos) : 50;
    cover.style.backgroundPosition = 'center ' + (isFinite(pos) ? Math.min(100, Math.max(0, pos)) : 50) + '%';
  }

  /* 一条动态的 HTML（列表和「翻下一页」都用它，保证长得一模一样） */
  function momentHtml(m) {
      var face = m.author && m.author.avatar ? '<img src="' + esc(m.author.avatar) + '" alt="" loading="lazy" decoding="async">' : esc(initials(m.author ? m.author.nickname : '?'));
      var nImg = (m.images || []).length;
      var imgs = nImg
        ? '<div class="wx-moment-imgs is-' + Math.min(9, nImg) + '">' + m.images.map(function (src) {
          return '<img src="' + esc(src) + '" alt="" data-img="' + esc(src) + '"' +
              ' loading="lazy" decoding="async">';
          }).join('') + '</div>'
        : '';
      var likes = (m.likes || []).length
        ? '<div class="likes"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 20.2l-1.2-1.1C6.1 14.9 3.3 12.4 3.3 9.3c0-2.5 2-4.5 4.5-4.5 1.4 0 2.8.7 4.2 2.1 1.4-1.4 2.8-2.1 4.2-2.1 2.5 0 4.5 2 4.5 4.5 0 3.1-2.8 5.6-7.5 9.8L12 20.2z"/></svg><span>' + m.likes.map(function (l) { return esc(l.nickname); }).join('，') + '</span></div>' : '';
      var cmts = (m.comments || []).length
        ? m.comments.map(function (c) { return '<div class="cmt"><b>' + esc(c.nickname) + '</b>：' + esc(c.content) + '</div>'; }).join('') : '';
      var social = (likes || cmts) ? '<div class="wx-moment-social">' + likes + cmts + '</div>' : '';
      return '<div class="wx-moment" data-moment="' + esc(m.id) + '">' +
        '<div class="wx-moment-avatar" data-uid="' + esc((m.author && m.author.id) || '') + '">' + face + '</div>' +
        '<div class="wx-moment-main">' +
          '<div class="wx-moment-name">' + esc(m.author ? m.author.nickname : '未知') + '</div>' +
          (m.content ? '<p class="wx-moment-text">' + esc(m.content) + '</p>' : '') +
          imgs +
          '<div class="wx-moment-foot">' +
            '<span class="wx-moment-time">' + esc(momentTime(m.createdAt)) + '</span>' +
            // 微信那种深色小方块 + 三个点，点开才有赞 / 评论
            '<button class="wx-moment-more' + (m.likedByMe ? ' is-liked' : '') + '" data-more="' + esc(m.id) + '" aria-label="更多操作">' +
              '<i></i><i></i><i></i>' +
            '</button>' +
          '</div>' + social +
        '</div></div>';
  }

  function momentsFoot() {
    if (!S.momentsMore) return '<div class="wx-empty" id="mmFoot">没有更多了</div>';
    return '<div class="wx-empty" id="mmFoot">正在加载…</div>';
  }

  function renderMoments() {
    $('momentList').innerHTML = (S.moments.map(momentHtml).join('') || '<div class="wx-empty">还没有动态</div>') +
      (S.moments.length ? momentsFoot() : '');
    if (window.mmFitIn) window.mmFitIn($('momentList'));
  }

  /* 往下滚到底 → 再拉一页（一页 30 条，一直能翻到最早那条） */
  function loadMoreMoments() {
    if (!S.momentsMore || S.momentsLoading) return;
    var last = S.moments[S.moments.length - 1];
    if (!last) return;
    S.momentsLoading = true;
    /* 游标要带上 id：同一毫秒发的几十条如果只按时间戳翻页会被整段跳过 */
    var url = '/moments?limit=30&before=' + encodeURIComponent(last.createdAt) +
      '&beforeId=' + encodeURIComponent(last.id) +
      (S.momentsUser ? '&userId=' + encodeURIComponent(S.momentsUser) : '');
    api(url).then(function (d) {
      var more = d.moments || [];
      var foot = $('mmFoot');
      if (foot) foot.remove();
      if (more.length) {
        /* 去重：万一翻页期间有人发了新动态，边界上可能重复一条 */
        var have = {};
        S.moments.forEach(function (m) { have[m.id] = 1; });
        var fresh = more.filter(function (m) { return !have[m.id]; });
        S.moments = S.moments.concat(fresh);
        $('momentList').insertAdjacentHTML('beforeend', fresh.map(momentHtml).join(''));
        if (window.mmFitIn) window.mmFitIn($('momentList'));
      }
      S.momentsMore = !!d.hasMore && more.length > 0;
      $('momentList').insertAdjacentHTML('beforeend', momentsFoot());
    }).catch(function () {
      var foot = $('mmFoot'); if (foot) foot.textContent = '加载失败，稍后再试';
    }).then(function () { S.momentsLoading = false; });
  }

  /* ---------------------------------------------------------- WebSocket */
  var reconnectDelay = 1000;
  function connect() {
    var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    try { socket = new WebSocket(proto + '//' + location.host); } catch (e) { return setTimeout(connect, reconnectDelay); }
    socket.onopen = function () {
      reconnectDelay = 1000;
      if ($('netBar')) $('netBar').hidden = true;      // 连回来了就把提示条收掉
    };
    socket.onclose = function () {
      if ($('netBar') && !$('app').hidden) $('netBar').hidden = false;   // 断了挂一条提示
      setTimeout(connect, reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 1.6, 8000);
    };
    socket.onmessage = function (ev) {
      var msg; try { msg = JSON.parse(ev.data); } catch (e) { return; }
      if (msg.type === 'call' || msg.type === 'call-error') { handleCallEvent(msg); return; }
      if (msg.type === 'ready') {
        S.online = {};
        (msg.online || []).forEach(function (id) { S.online[id] = true; });
        if (msg.momentUnread != null) setTabBadge('tabBadgeMoments', msg.momentUnread, true);
        /* 长连接重连（比如手机刚从后台回来）：把待处理好友申请的红点补上 */
        if (msg.friendRequests != null) setTabBadge('tabBadgeContacts', msg.friendRequests);
        return;
      }
    if (msg.type === 'message') {
        var m = msg.message;
        var list = S.messages[m.chatId] = S.messages[m.chatId] || [];
        if (msg.clientId) {
          var i = list.findIndex(function (x) { return x.id === msg.clientId; });
          if (i >= 0) list.splice(i, 1);
        }
        if (!list.some(function (x) { return x.id === m.id; })) list.push(m);
        if (S.activeChat === m.chatId) { renderMessages(); markRead(m.chatId); }
        /* AI 通话中：对方（机器人）说的话用语音念出来 */
        if (call && call.ai && m.senderId === call.peerId && m.kind === 'text' && !m.recalled) {
          aiCallSpeak(m.content);
        }
        scheduleChatReload();
        // 收到礼物（包括自己送出的回执）→ 铺满屏幕刷一下
        if (m.kind === 'gift') {
          if (!(msg.clientId && giftLocalIds[msg.clientId])) {
            var mineGift = m.senderId === S.me.id;
            var chatOfMsg = S.chats.filter(function (c) { return c.id === m.chatId; })[0] || {};
            playGiftFlood(giftInfoOf(m.content), mineGift ? '我' : (m.senderName || chatOfMsg.title || '对方'));
          }
        }
        var ids = Object.keys(giftLocalIds);
        if (ids.length > 20) ids.slice(0, ids.length - 20).forEach(function (k) { delete giftLocalIds[k]; });
        return;
      }
      if (msg.type === 'read' || msg.type === 'presence' || msg.type === 'chat' || msg.type === 'friend') { scheduleChatReload(); loadContacts(); return; }
      /* 直播专场：弹幕 / 在线人数 / 点赞（只在对应房间里处理） */
      if (msg.type === 'live') {
        if (!liveRoom || msg.roomId !== liveRoom.id) return;
        if (msg.action === 'danmaku') {
          /* 这个回调在另一层作用域里，弹幕函数挂在 window 上给它用 */
          if (window.mmAddDanmaku) window.mmAddDanmaku(msg.from || '观众', msg.text || '');
          return;
        }
        if (msg.action === 'count') { $('liveRoomCount').textContent = (msg.watching || 0) + ' 人在看'; return; }
        if (msg.action === 'like') { return; }
        return;
      }
      if (msg.type === 'moment') { loadMomentsBadge(); return; }
      // 后台改了 ＋ 面板：在线的直接换，不用刷新
      if (msg.type === 'pluspanel') {
        S.plusItems = msg.items || S.plusItems;
        plusBuilt = false;
        if (!$('plusPanel').hidden) buildPlusPanel();
        return;
      }
      if (msg.type === 'gifts') {
        S.gifts = (msg.gifts || []).filter(function (g) { return g.enabled !== false; });
        giftBuilt = false;
        if (!$('giftPanel').hidden) buildGiftPanel();
        return;
      }
      if (msg.type === 'stickers') {
        S.stickerPacks = (msg.packs || []).filter(function (p) { return p.enabled !== false; });
        if (!$('stickerScreen').hidden) renderStickers();
        return;
      }
      if (msg.type === 'balance' && msg.balance !== undefined) {   // 后台充值了，余额马上跟着变
        if (S.me) S.me.balance = Number(msg.balance) || 0;
        paintPayMethod();
        if ($('pmList') && !$('pmMask').hidden) renderPayMethods();
        return;
      }
      if (msg.type === 'transfer' && msg.transfer) {               // 转账单状态变了：收钱 / 退回
        var tl = S.messages[msg.chatId] || [];
        var patched = false;
        for (var ti = 0; ti < tl.length; ti++) {
          var ti0 = tl[ti].kind === 'transfer' ? transferInfoOf(tl[ti].content) : null;
          if ((ti0 && ti0.id === msg.transfer.id) || tl[ti].id === msg.messageId) {
            tl[ti].content = JSON.stringify(msg.transfer);
            patched = true;
            break;
          }
        }
        /* 对方收了钱：聊天里的气泡、会话列表那条预览、账单页都要跟着变（不用重进页面） */
        if (S.activeChat === msg.chatId) {
          renderMessages();
          updateTransferBubbles(msg.transfer.id, msg.transfer.status);
        }
        loadChats();
        if ($('billListScreen') && !$('billListScreen').hidden) loadBillsPage(S.billsMonth || '');
        if (!$('billScreen').hidden && billCurrent && billCurrent.id === msg.transfer.id) openBillDetail(msg.transfer.id);
        if (msg.event === 'received' && msg.transfer.toId === (S.me && S.me.id)) toast('已收款 ' + money(msg.transfer.amount));
        if (msg.event === 'received' && msg.transfer.fromId === (S.me && S.me.id)) toast('对方已收款 ' + money(msg.transfer.amount));
        if (msg.event === 'refunded' && msg.transfer.fromId === (S.me && S.me.id)) toast('超过 24 小时未收款，' + money(msg.transfer.amount) + ' 已退回你的余额');
        return;
      }
      if (msg.type === 'statuses') {
        S.statusCats = msg.categories || S.statusCats;
        if (!$('statusScreen').hidden) renderStatusPage();
        return;
      }
      // 资料变了（自己改的 or 好友改的）
      if (msg.type === 'profile' && msg.user) {
        if (S.me && msg.user.id === S.me.id) {
          S.me = Object.assign({}, S.me, msg.user);
          fillMe();
        } else {
          var fi = (S.friends || []).findIndex(function (f) { return f.id === msg.user.id; });
          if (fi >= 0) {
            S.friends[fi] = Object.assign({}, S.friends[fi], msg.user);
            renderContacts();
          }
          if (S.messages) {
            Object.keys(S.messages).forEach(function (cid) {
              (S.messages[cid] || []).forEach(function (m) {
                if (m.senderId === msg.user.id) {
                  m.senderName = msg.user.nickname;
                  m.senderAvatar = msg.user.avatar;
                }
              });
            });
            if (S.activeChat) renderMessages();
          }
          scheduleChatReload();
        }
        return;
      }
    };
  }

  /* ---------------------------------------------------------- 事件绑定 */
  function bind() {
    /* 图片没加载出来（或路径失效）时，浏览器/手机 WebView 会在原地画一个「?」占位，
       看起来很像坏了。这里统一把它藏掉：加载中就显示底下的玻璃底图，加载失败也不显示问号。 */
    document.addEventListener('error', function (e) {
      var t = e.target;
      if (t && t.tagName === 'IMG') { t.style.visibility = 'hidden'; }
    }, true);
    (function paintImgStates() {
      var mark = function (img) {
        if (!img) return;
        if (img.complete && img.naturalWidth === 0) img.style.visibility = 'hidden';   /* 已经失败的 */
        img.addEventListener('load', function () { img.style.visibility = ''; });
      };
      document.querySelectorAll('img').forEach(mark);
      new MutationObserver(function (muts) {
        muts.forEach(function (m) {
          Array.prototype.forEach.call(m.addedNodes || [], function (n) {
            if (n.nodeType !== 1) return;
            if (n.tagName === 'IMG') mark(n);
            if (n.querySelectorAll) n.querySelectorAll('img').forEach(mark);
          });
        });
      }).observe(document.body, { childList: true, subtree: true });
    })();
    $('lgBtn').addEventListener('click', doLogin);
    $('lgPass').addEventListener('keydown', function (e) { if (e.key === 'Enter') doLogin(); });
    $('lgCodeBtn').addEventListener('click', sendPhoneCode);
    // 同步提示前面的圆圈：能自己打勾，没勾是空圈、打勾是绿色
    (function bindAgree() {
      var btn = $('lgAgree');
      if (!btn) return;
      var saved = '';
      try { saved = localStorage.getItem('wx-agree') || ''; } catch (e) { }
      btn.classList.toggle('is-on', saved === '1');
      btn.addEventListener('click', function () {
        var on = !btn.classList.contains('is-on');
        btn.classList.toggle('is-on', on);
        try { localStorage.setItem('wx-agree', on ? '1' : '0'); } catch (e) { }
      });
    })();
    $('lgPhone').addEventListener('input', function () {
      this.value = this.value.replace(/\D/g, '').slice(0, 11);
    });
    $('lgCode').addEventListener('input', function () {
      this.value = this.value.replace(/\D/g, '').slice(0, 6);
    });
    $('lgCode').addEventListener('keydown', function (e) { if (e.key === 'Enter') doLogin(); });
    $('lgPhone').addEventListener('keydown', function (e) { if (e.key === 'Enter') $('lgCode').focus(); });
    // 其他方式登录 / 返回手机号登录
    $('lgOther').addEventListener('click', function () {
      var showPass = $('lgPassPanel').hidden;
      $('lgPassPanel').hidden = !showPass;
      $('lgOther').textContent = showPass ? '用手机号登录' : '其他方式登录';
      $('lgCodeBtn').hidden = showPass;
      $('lgPhone').closest('.lg-row').style.display = showPass ? 'none' : '';
      $('lgCode').closest('.lg-row').style.display = showPass ? 'none' : '';
      document.querySelector('.lg-hint').style.display = showPass ? 'none' : '';
      $('lgErr').hidden = true;
    });
    $('lgBack').addEventListener('click', function () {
      if (!$('lgPassPanel').hidden) { $('lgOther').click(); return; }
      $('lgPhone').value = '';
      $('lgCode').value = '';
      $('lgErr').hidden = true;
    });
    // 国家地区：+86 为主，给几个常用区号
    $('lgCountry').addEventListener('click', function () {
      sheet([
        { label: '中国大陆 (+86)', run: function () { setCountry('中国大陆', '+86'); } },
        { label: '中国香港 (+852)', run: function () { setCountry('中国香港', '+852'); } },
        { label: '中国澳门 (+853)', run: function () { setCountry('中国澳门', '+853'); } },
        { label: '中国台湾 (+886)', run: function () { setCountry('中国台湾', '+886'); } },
        { label: '美国 (+1)', run: function () { setCountry('美国', '+1'); } }
      ]);
    });

    $('tabbar').addEventListener('click', function (e) {
      var t = e.target.closest('.wx-tab'); if (!t) return;
      switchTab(t.getAttribute('data-tab'));
    });

    /* ---------------- 会话列表左滑：标为未读 / 不显示 / 删除（和微信一致） ---------------- */
    var swipeOpen = null;
    /* 参考图量出来的尺寸：微信是一条 249px 的长条
       （标为未读 84 + 不显示该聊天 165）；再往里滑过 SWIPE_DEEP 就是第二层
       「清空记录同时不显示聊天」（变红、两行字）。 */
    var SWIPE_W = 249;
    var SWIPE_DEEP = 289;      /* 过这条线：那条加宽到 249，显示「不显示该聊天」（橙） */
    var SWIPE_DEEPER = 370;    /* 再过这条线：变红，显示「清空记录同时不显示聊天」 */
    function closeSwipe(anim) {
      if (!swipeOpen) return;
      var s = swipeOpen; swipeOpen = null;
      s.classList.remove('is-deep', 'is-deeper', 'confirm-hide', 'confirm-del');
      s.style.transition = anim === false ? 'none' : '';
      s.style.transform = '';
    }
    function openSwipe(slide, deep) {
      closeSwipe();
      swipeOpen = slide;
      slide.style.transition = '';
      /* 第二层时那一条会加宽到 249（盖掉标为未读），所以要多推 84 */
      slide.style.transform = 'translateX(-' + SWIPE_W + 'px)';
    }
    function doRowAction(act, id, deep) {
      if (!id) return;
      if (act === 'unread') {
        api('/chats/' + encodeURIComponent(id) + '/unread', { method: 'POST' })
          .then(function () { toast('已标为未读'); return loadChats(); })
          .catch(function (e) { toast(e.message || '操作失败'); });
        return;
      }
      /* 不显示该聊天：只从自己的列表里移除（对方不受影响）；
         第二层「清空记录同时不显示聊天」：把记录一起清掉再隐藏（带 ?clear=1）。 */
      /* 连记录一起清掉的情况：滑动到第二层，或者直接点「删除」 */
      var clear = deep === 2 || act === 'del';
      api('/chats/' + encodeURIComponent(id) + (clear ? '?clear=1' : ''), { method: 'DELETE' })
        .then(function () {
          S.chats = (S.chats || []).filter(function (c) { return c.id !== id; });
          renderChats();
          toast(act === 'del' ? '已删除' : (deep === 2 ? '已清空记录并设为不显示' : '已不显示该聊天'));
        })
        .catch(function (e) { toast(e.message || '操作失败'); });
    }
    /* 聊天页：跟 iPhone 微信一样，手指左右一滑就回上一页（列表）。
       只有横向手势才接管，竖向照常滚消息；表情/加号面板里不抢手势。 */
    var chatSlideOut = null;
    (function bindChatBack() {
      var scr = $('chatScreen'); if (!scr) return;
      var start = null, timer = null;
      var W = Math.max(320, window.innerWidth || 420);
      function drag(px) { scr.style.setProperty('--chat-drag', px + 'px'); }
      function clearDrag() {
        clearTimeout(timer);
        scr.classList.remove('is-drag', 'is-swiping');
        scr.style.removeProperty('--chat-drag');
        scr.style.animation = '';                 // 恢复进场动画，下次打开照样有
      }
      /* 点左上角返回键也走同一套滑出动画（输入栏跟着一起滑） */
      chatSlideOut = function (done) {
        if (scr.hidden) { done(); return; }
        scr.style.animation = 'none';             // 进场动画会盖住 transform，先关掉
        scr.classList.remove('is-swiping');
        drag(W);
        clearTimeout(timer);
        timer = setTimeout(function () { clearDrag(); done(); }, 205);
      };
      scr.addEventListener('touchstart', function (e) {
        if (e.touches.length !== 1) { start = null; return; }
        var t = e.target;
        if (t && t.closest && t.closest('.wx-emoji, .wx-plus')) { start = null; return; }   // 面板里左右翻页，别抢
        if ($('phView') && !$('phView').hidden) { start = null; return; }                    // 图片预览时不抢
        start = { x: e.touches[0].clientX, y: e.touches[0].clientY, axis: '', dx: 0 };
      }, { passive: true });
      scr.addEventListener('touchmove', function (e) {
        if (!start) return;
        var dx = e.touches[0].clientX - start.x;
        var dy = e.touches[0].clientY - start.y;
        if (!start.axis) {
          if (Math.abs(dx) < 10 && Math.abs(dy) < 10) return;
          start.axis = Math.abs(dx) > Math.abs(dy) * 1.15 ? 'x' : 'y';
          if (start.axis === 'x') {
            scr.style.animation = 'none';             // 进场动画会盖住 transform，拖动时先关掉
            scr.classList.add('is-drag', 'is-swiping');
          }
          else { start = null; return; }
        }
        start.dx = dx;
        drag(Math.max(-W * 0.7, Math.min(W, dx)));
      }, { passive: true });
      scr.addEventListener('touchend', function () {
        if (!start) return;
        var wasX = start.axis === 'x', dx = start.dx;
        start = null;
        if (!wasX) { clearDrag(); return; }
        scr.classList.remove('is-swiping');                 // 松手后允许过渡动画
        if (Math.abs(dx) >= 64) {                           // 滑够了：整页滑出屏幕再关
          drag(dx > 0 ? W : -W);
          clearTimeout(timer);
          timer = setTimeout(function () { clearDrag(); closeChat(); }, 180);
        } else {
          drag(0);                                          // 不够：弹回原位
          clearTimeout(timer);
          timer = setTimeout(clearDrag, 260);
        }
      }, { passive: true });
      scr.addEventListener('touchcancel', function () { start = null; drag(0); clearTimeout(timer); timer = setTimeout(clearDrag, 260); }, { passive: true });
    })();

    /* ---------------- 其他页面：返回时整页向左/右滑出 + 跟手返回 ----------------
       和聊天页一样的体验：手指横向一拖整页跟着走，松手过了 64px 就滑出去并返回；
       点左上角「‹」也是先滑出动画再关闭。 */
    (function bindSlidePages() {
      var pages = [].slice.call(document.querySelectorAll('.wx-chat, .wx-moments')).filter(function (el) {
        return el.id !== 'chatScreen';                  // 聊天页有自己的那套
      });
      pages.forEach(function (el) {
        var back = el.querySelector('.wx-back');
        var start = null, timer = 0, W = 0, skipNext = false;
        function setT(v, dur) {
          el.style.animation = 'none';        // 进场动画（wxPageIn）会盖住 transform，拖动/滑出时先关掉
          el.style.transition = dur ? 'transform ' + dur + 'ms cubic-bezier(0.2, 0.9, 0.24, 1)' : 'none';
          el.style.transform = v ? 'translateX(' + v + 'px)' : '';
        }
        function reset(dur) {
          clearTimeout(timer);
          setT(0, dur === 0 ? 0 : 200);
          timer = setTimeout(function () { el.style.transition = ''; el.style.transform = ''; el.style.animation = ''; }, 230);
        }
        /* 左上角返回键：先滑出，再执行原来的返回逻辑 */
        if (back) {
          el.addEventListener('click', function (e) {
            if (skipNext) { skipNext = false; return; }         // 动画放完这次放过，真去执行返回
            var t = e.target;
            if (!t || !t.closest || t.closest('.wx-back') !== back || el.hidden) return;
            e.preventDefault();
            e.stopPropagation();                       // 别让按钮自己的处理器立刻关掉
            W = el.offsetWidth || 420;
            setT(W, 205);
            clearTimeout(timer);
            timer = setTimeout(function () {
              el.style.transition = ''; el.style.transform = ''; el.style.animation = '';
              skipNext = true;
              back.click();
            }, 200);
          }, true);                                    // 捕获阶段：比按钮自己的监听更早
        }
        /* 手指跟手：横向拖 = 返回 */
        el.addEventListener('touchstart', function (e) {
          if (e.touches.length !== 1 || el.hidden) { start = null; return; }
          var t = e.target;
          if (t && t.closest && t.closest('input, textarea, .wx-emoji, .wx-plus, .ph-view, .pay-mask, .pm-mask, .pub-mask, .ask-mask, .wx-sheet, .nt-mask, .mm-mask')) { start = null; return; }
          start = { x: e.touches[0].clientX, y: e.touches[0].clientY, axis: '', dx: 0 };
          W = el.offsetWidth || 420;
        }, { passive: true });
        el.addEventListener('touchmove', function (e) {
          if (!start) return;
          var dx = e.touches[0].clientX - start.x;
          var dy = e.touches[0].clientY - start.y;
          if (!start.axis) {
            if (Math.abs(dx) < 12 && Math.abs(dy) < 12) return;
            start.axis = Math.abs(dx) > Math.abs(dy) * 1.2 ? 'x' : 'y';
            if (start.axis !== 'x') { start = null; return; }
          }
          start.dx = dx;
          setT(Math.max(-W * 0.6, Math.min(W, dx)), 0);
        }, { passive: true });
        el.addEventListener('touchend', function () {
          if (!start) return;
          var wasX = start.axis === 'x', dx = start.dx;
          start = null;
          if (!wasX) { reset(0); return; }
          if (Math.abs(dx) >= 64) {
            setT(dx > 0 ? W : -W, 200);
            clearTimeout(timer);
            timer = setTimeout(function () {
              el.style.transition = ''; el.style.transform = ''; el.style.animation = '';
              if (back) { skipNext = true; back.click(); }
            }, 200);
          } else {
            reset(200);
          }
        }, { passive: true });
        el.addEventListener('touchcancel', function () { start = null; reset(0); }, { passive: true });
      });
    })();

    (function bindSwipe() {
      var list = $('chatList'); if (!list) return;
      var start = null;
      list.addEventListener('touchstart', function (e) {
        /* 手指落在「标为未读 / 不显示 / 删除」上时：既不滑也不收，
           否则「点别处收起」会先把整行收回去，按钮就永远点不到了 */
        if (e.target.closest && e.target.closest('.wx-row-actions')) { start = null; return; }
        var slide = e.target.closest && e.target.closest('.wx-row-slide');
        if (!slide) { closeSwipe(true); return; }
        start = {
          x: e.touches[0].clientX, y: e.touches[0].clientY, slide: slide,
          base: slide === swipeOpen ? -SWIPE_W : 0, moved: false, value: 0
        };
      }, { passive: true });
      list.addEventListener('touchmove', function (e) {
        if (!start) return;
        var dx = e.touches[0].clientX - start.x;
        var dy = e.touches[0].clientY - start.y;
        if (!start.moved && Math.abs(dx) < 6 && Math.abs(dy) < 6) return;
        if (Math.abs(dx) < Math.abs(dy)) { start = null; return; }   /* 竖向：交给列表滚动 */
        start.moved = true;
        var v = Math.max(-(SWIPE_W + 152), Math.min(0, start.base + dx));
        start.value = v;
        if (swipeOpen && start.slide !== swipeOpen) closeSwipe(true);
        start.slide.style.transition = 'none';
        start.slide.style.transform = 'translateX(' + v + 'px)';
      }, { passive: true });
      list.addEventListener('touchend', function () {
        if (!start) return;
        var s = start.slide, moved = start.moved, v = start.value;
        start = null;
        s.style.transition = '';
        if (!moved) return;
        if (v <= -SWIPE_W * 0.35) openSwipe(s); else closeSwipe(true);
      });
      /* 滑开以后，点别的地方自动收起 */
      document.addEventListener('touchstart', function (e) {
        if (!swipeOpen) return;
        if (e.target.closest && e.target.closest('.wx-row-actions')) return;   /* 点按钮时不收 */
        if (!e.target.closest || !e.target.closest('.wx-row-slide')) closeSwipe(true);
      }, { passive: true });
    })();

    $('chatList').addEventListener('click', function (e) {
      var act = e.target.closest && e.target.closest('[data-act]');
      if (act) {
        e.preventDefault(); e.stopPropagation();
        var actName = act.getAttribute('data-act');
        var actId = act.getAttribute('data-id');
        /* 按钮在 .wx-row-actions 里，是 .wx-row-slide 的兄弟节点，所以要往上找到 .wx-row 再取 slide */
        var actRow = act.closest('.wx-row');
        var actSlide = actRow ? actRow.querySelector('.wx-row-slide') : null;
        if (actName === 'unread') {                 /* 标为未读：一下就到 */
          doRowAction('unread', actId);
          closeSwipe(true);
          return;
        }
        /* 「不显示」和「删除」都还有一层：第一下先把这一条撑成 249 的长条
           （不显示该聊天 / 清空记录同时不显示聊天），再点一下才真的执行；
           点另一个按钮会切换过去，点别处就整个收起来。 */
        var wantClass = actName === 'del' ? 'confirm-del' : 'confirm-hide';
        if (actSlide && !actSlide.classList.contains(wantClass)) {
          actSlide.classList.remove('confirm-hide', 'confirm-del');
          actSlide.classList.add(wantClass);
          return;
        }
        doRowAction(actName, actId, actName === 'del');
        closeSwipe(true);
        return;
      }
      var row = e.target.closest('[data-chat]'); if (!row) return;
      if (swipeOpen) { closeSwipe(true); return; }   /* 已经滑开时，点一下先收起 */
      openChat(row.getAttribute('data-chat'));
    });
    // 滑动时先不重画（passive 监听，不阻塞滚动）
    ['chatList', 'momentList', 'messages', 'contactList'].forEach(function (id) {
      var el = $(id);
      if (el) el.addEventListener('scroll', markScrolling, { passive: true });
    });
    /* 打字时不要每敲一个字就整表重排（60 多个会话行全量 innerHTML），
       停 140ms 再画一次，输入就不会顿。 */
    (function () {
      var t = 0;
      $('chatSearch').addEventListener('input', function () {
        clearTimeout(t);
        t = setTimeout(renderChats, 140);
      });
    })();
    // 搜索框：没点进去时放大镜 + 「搜索」居中（微信那样）
    (function bindSearchCenter() {
      var input = $('chatSearch');
      var box = input.closest('.ws-box');
      if (!box) return;
      var sync = function () {
        var active = document.activeElement === input || input.value.length > 0;
        box.classList.toggle('is-center', !active);
      };
      input.addEventListener('focus', sync);
      input.addEventListener('blur', sync);
      input.addEventListener('input', sync);
      sync();
    })();

    $('contactList').addEventListener('click', function (e) {
      var nf = e.target.closest('#newFriends');
      if (nf) { openNewFriends(); return; }
      var fn = e.target.closest('.ct-func');
      if (fn && !nf) {
        var tips = {
          ctChatOnly: '仅聊天的朋友：只有聊天记录、没加好友的人会出现在这里',
          ctTags: '标签：还没建过标签',
          ctService: '服务号：暂时没有关注的服务号',
          ctWork: '企业微信联系人：还没绑定企业微信',
          ctMyWork: '我的企业：还没创建企业'
        };
        toast(tips[fn.id] || '这个功能还没开');
        return;
      }
      var ctFace = e.target.closest('.ct-avatar');            // 点头像 → 名片；点别处还是开聊天
      if (ctFace) {
        var ctUid = ctFace.getAttribute('data-uid');
        if (ctUid) { openCard(ctUid); return; }
      }
      var f = e.target.closest('[data-friend]'); if (!f) return;
      var id = f.getAttribute('data-friend');
      api('/chats/direct', { method: 'POST', body: JSON.stringify({ userId: id }) }).then(function (d) {
        var chat = d.chat;
        if (!S.chats.some(function (c) { return c.id === chat.id; })) S.chats.unshift(chat);
        renderChats(); openChat(chat.id);
      }).catch(function (err) { toast(err.message); });
    });

    /* 通讯录：搜索 + 右侧 A-Z 索引（点 / 滑都能跳） */
    if ($('ctSearch')) {
      /* 通讯录同理：打字时防抖，别每一下都重建整份联系人列表 */
      (function () {
        var t = 0;
        $('ctSearch').addEventListener('input', function () {
          clearTimeout(t);
          t = setTimeout(renderContacts, 140);
        });
      })();
    }
    if ($('ctIndex')) {
      $('ctIndex').addEventListener('click', function (e) {
        var s = e.target.closest('.ct-idx'); if (!s) return;
        jumpToLetter(s.getAttribute('data-l'));
      });
      (function bindIndexDrag() {
        var box = $('ctIndex');
        var pick = function (ev) {
          var items = [].slice.call(box.querySelectorAll('.ct-idx'));
          if (!items.length) return;
          var t = (ev.touches && ev.touches[0]) ? ev.touches[0] : ev;
          var first = items[0].getBoundingClientRect();
          var last = items[items.length - 1].getBoundingClientRect();
          var each = items.length > 1 ? (last.top - first.top) / (items.length - 1) : first.height;
          var i = Math.round((t.clientY - first.top) / Math.max(1, each));
          i = Math.max(0, Math.min(items.length - 1, i));
          var L = items[i].getAttribute('data-l');
          if (L) jumpToLetter(L);
        };
        box.addEventListener('touchstart', function (e) { box.classList.add('is-touch'); pick(e); }, { passive: true });
        box.addEventListener('touchmove', function (e) { pick(e); }, { passive: true });
        box.addEventListener('touchend', function () {
          box.classList.remove('is-touch');
          var b = $('ctLetter');
          if (b) { clearTimeout(b.__t); b.__t = setTimeout(function () { b.hidden = true; }, 420); }
        }, { passive: true });
      })();
    }

    /* 发现页的行全部由后台配置渲染（/api/discover），点了按 action 决定去哪 */
    $('discoverList').addEventListener('click', function (e) {
      var row = e.target.closest ? e.target.closest('[data-dsc]') : null;
      if (!row) return;
      var it = (S.discover || [])[Number(row.getAttribute('data-dsc'))];
      if (!it) return;
      if (it.action === 'moments') { openMoments(null); return; }
      if (it.action === 'news') { openNews(); return; }
      if (it.action === 'nearby') { openNearby(); return; }
      if (it.action === 'shake') { openShake(); return; }
      if (it.action === 'channels') { openChannels(); return; }
      if (it.action === 'live') { openLive(); return; }
      if (it.action === 'games') { openGames(); return; }
      toast(it.label + '：还没做，排在下一批');
    });
    $('nfBack').addEventListener('click', function () { $('newFriendsScreen').hidden = true; });
    /* ---------------- 附近的人 ---------------- */
    $('nearbyBack').addEventListener('click', function () { $('nearbyScreen').hidden = true; });
    /* ---------------- 摇一摇 ---------------- */
    /* ---------------- 视频号（抖音式上下刷） ---------------- */
    function openChannels() {
      $('channelsScreen').hidden = false;
      $('feedList').innerHTML = '<div class="feed-empty">正在加载…</div>';
      channelsDone = false; channelsBusy = false;
      api('/feed').then(function (d) { feed = d.items || []; renderFeed(); })
        .catch(function (e) { $('feedList').innerHTML = '<div class="feed-empty">' + esc(e.message || '加载失败') + '</div>'; });
    }
    /* 一条视频的 DOM（渲染全量和追加时共用） */
    /* 右侧按钮：毛玻璃圆底 + 图标 + 数字（比原来光秃秃的图标精致） */
    function railBtn(attr, idx, icon, count, active, color) {
      return '<button type="button" ' + attr + '="' + idx + '" style="display:flex;flex-direction:column;align-items:center;gap:5px;border:0;background:none;padding:0;color:' + color + '">' +
        '<span style="width:44px;height:44px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:19px;' +
          'background:rgba(0,0,0,' + (active ? '.34' : '.22') + ');' +
          'backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px);' +
          'border:1px solid rgba(255,255,255,' + (active ? '.36' : '.18') + ');' +
          'box-shadow:0 3px 10px rgba(0,0,0,.35)">' + icon + '</span>' +
        '<span style="font-size:12.5px;font-weight:600;text-shadow:0 1px 3px rgba(0,0,0,.5)">' + count + '</span></button>';
    }

    function feedItemHtml(v, i) {
      return '<div class="feed-item" data-i="' + i + '">' +
        (v.video ? '<video src="' + esc(v.video) + '" playsinline muted loop preload="auto"></video>' : '') +
        /* 抖音式底部细进度条 */
        '<div class="fd-progress" style="position:absolute;left:0;right:0;bottom:0;height:3px;background:rgba(255,255,255,.22);z-index:3;cursor:pointer">' +
          '<i style="display:block;height:100%;width:0;background:#fff"></i></div>' +
        /* 短剧：左上角显示当前集数，旁边「选集」 */
        (v.ep ? '<div style="position:absolute;top:calc(12px + env(safe-area-inset-top,0px));left:12px;display:flex;gap:8px;align-items:center;z-index:3">' +
          '<span style="background:rgba(0,0,0,.45);color:#fff;font-size:13px;font-weight:600;padding:4px 10px;border-radius:999px">' + esc(v.ep) + '</span>' +
          ((v.epTotal || 0) > 1 ? '<button type="button" data-ep="' + i + '" style="background:rgba(0,0,0,.45);color:#fff;font-size:13px;font-weight:600;padding:4px 10px;border:0;border-radius:999px">选集</button>' : '') +
        '</div>' : '') +
        '<div class="fd-shade"></div>' +
        '<div class="feed-info"><div class="fd-name">@' + esc(v.author.name) + '</div>' +
          '<div class="fd-desc">' + esc(v.desc) + '</div>' +
          '<div class="fd-music">♪ ' + esc(v.music || '原创声音') + '</div></div>' +
        '<div class="feed-rail">' +
          '<div class="fd-ava">' + (v.author.avatar ? '<img src="' + esc(v.author.avatar) + '" alt="">' : esc(initials(v.author.name))) + '</div>' +
          railBtn('data-like', i, '❤', v.likes || 0, !!v.liked, v.liked ? '#ff4d6d' : '#fff') +
          railBtn('data-cmt', i, '💬', v.comments || 0, false, '#fff') +
          railBtn('data-fav', i, '⭐', v.favorites || 0, !!v.favorited, v.favorited ? '#ffc542' : '#fff') +
          railBtn('data-share', i, '↗', v.shares || 0, false, '#fff') +
        '</div></div>';
    }
    /* 无限刷：滑到接近底部就去拿下一批，接在后面（服务端每次给新的那批） */
    var channelsBusy = false, channelsDone = false;
    var openFeedComments = null;      // 评论面板（在 renderFeed 里赋值，避免作用域问题）
    function loadMoreChannels() {
      if (channelsBusy || channelsDone) { return; }
      channelsBusy = true;
      api('/feed').then(function (d) {
        var more = d.items || [];
        channelsBusy = false;
        if (!more.length) { channelsDone = true; return; }
        var box = $('feedList');
        var start = feed.length;
        var known = {};
        feed.forEach(function (x) { known[x.id] = 1; });
        var fresh = more.filter(function (x) { return !known[x.id]; });
        if (!fresh.length) { fresh = more; }        // 一轮刷完了：允许重复，别让用户滑到底
        feed = feed.concat(fresh);
        box.insertAdjacentHTML('beforeend', fresh.map(function (v, i) { return feedItemHtml(v, start + i); }).join(''));
        bindFeedProgress();
      }).catch(function () { channelsBusy = false; });
    }
    function renderFeed() {
      var box = $('feedList');
    /* 底部进度条：跟着播放走，点一下 / 按住拖可以跳转（抖音那套） */
    function bindFeedProgress() {
      var box = $('feedList');
      Array.prototype.forEach.call(box.querySelectorAll('.feed-item'), function (cell) {
        var v = cell.querySelector('video');
        var bar = cell.querySelector('.fd-progress');
        if (!v || !bar) { return; }
        if (!v._pgBound) {
          v._pgBound = true;
          v.addEventListener('timeupdate', function () {
            var i = bar.querySelector('i');
            if (i && v.duration) { i.style.width = (v.currentTime / v.duration * 100) + '%'; }
          });
        }
        if (!bar._bound) {
          bar._bound = true;
          var seek = function (e) {
            var r = bar.getBoundingClientRect();
            var ratio = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
            var i2 = bar.querySelector('i');
            if (i2) { i2.style.width = (ratio * 100) + '%'; }
            if (v.duration) { v.currentTime = ratio * v.duration; }
          };
          bar.addEventListener('click', seek);
          bar.addEventListener('pointermove', function (e) { if (e.buttons === 1) { seek(e); } });
        }
      });
    }

    /* 短剧「选集」面板：列出整套剧集，点哪集滚到哪集 */
    window.openEpisodeSheet = function (k) {
      var item = feed[k];
      if (!item || !item.series) { return; }
      var ov = document.createElement('div');
      ov.style.cssText = 'position:fixed;left:0;right:0;top:0;bottom:0;background:rgba(0,0,0,.5);z-index:9999;display:flex;align-items:flex-end';
      ov.innerHTML = '<div style="background:#fff;color:#111;width:100%;max-height:70vh;border-radius:14px 14px 0 0;display:flex;flex-direction:column">' +
        '<div style="padding:12px 14px;font-weight:600;border-bottom:1px solid #eee">' + esc(item.seriesName || '选集') +
          '<span id="epClose" style="float:right;color:#888;font-weight:400">关闭</span></div>' +
        '<div id="epList" style="flex:1;overflow:auto;padding:10px 14px">正在加载…</div></div>';
      document.body.appendChild(ov);
      var close = function () { if (ov.parentNode) { ov.parentNode.removeChild(ov); } };
      ov.addEventListener('click', function (e) { if (e.target === ov || e.target.id === 'epClose') { close(); } });
      api('/feed/series?id=' + encodeURIComponent(item.series)).then(function (d) {
        var eps = d.items || [];
        var box = document.getElementById('epList');
        box.innerHTML = eps.map(function (ep) {
          return '<div data-go="' + esc(ep.id) + '" style="padding:11px 12px;border-radius:10px;background:#f5f5f5;margin-bottom:8px;display:flex;justify-content:space-between;cursor:pointer">' +
            '<b>' + esc(ep.ep || '') + '</b>' +
            '<span style="color:#888;font-size:13px">' + esc(String(ep.desc || '').slice(0, 16)) + '</span></div>';
        }).join('');
        box.addEventListener('click', function (e) {
          var go = e.target.closest('[data-go]');
          if (!go) { return; }
          var id = go.getAttribute('data-go');
          var target = eps.filter(function (x) { return x.id === id; })[0];
          var idx = -1;
          for (var i2 = 0; i2 < feed.length; i2++) { if (feed[i2].id === id) { idx = i2; break; } }
          if (idx < 0 && target) {                 // 不在当前这批里：插到当前这条后面
            var at = feed.indexOf(item) + 1;
            feed.splice(at, 0, target);
            var list = $('feedList');
            var top = list.scrollTop;
            renderFeed();
            idx = at;
            list.scrollTop = top;
          }
          close();
          var nodes = $('feedList').querySelectorAll('.feed-item');
          if (nodes[idx]) { nodes[idx].scrollIntoView({ behavior: 'smooth', block: 'start' }); }
        });
      }).catch(function (err) { document.getElementById('epList').textContent = err.message || '加载失败'; });
    };

    /* 评论面板：拉评论列表 + 发评论（服务端 /api/feed/comments 提供列表） */
    openFeedComments = function (k) {
      var item = feed[k];
      if (!item) { return; }
      var ov = document.createElement('div');
      ov.style.cssText = 'position:fixed;left:0;right:0;top:0;bottom:0;background:rgba(0,0,0,.5);z-index:9999;display:flex;align-items:flex-end';
      ov.innerHTML =
        '<div style="background:#fff;color:#111;width:100%;max-height:72vh;border-radius:14px 14px 0 0;display:flex;flex-direction:column">' +
          '<div style="padding:12px 14px;font-weight:600;border-bottom:1px solid #eee">' +
            '<span id="fcTitle">评论</span>' +
            '<span id="fcClose" style="float:right;color:#888;font-weight:400">关闭</span></div>' +
          '<div id="fcList" style="flex:1;overflow:auto;padding:8px 14px;font-size:14px">正在加载…</div>' +
          '<div style="display:flex;gap:8px;padding:10px 12px;border-top:1px solid #eee">' +
            '<input id="fcInput" placeholder="说点什么…" style="flex:1;border:1px solid #ddd;border-radius:8px;padding:9px 10px;font-size:14px">' +
            '<button id="fcSend" style="border:0;background:#07C160;color:#fff;border-radius:8px;padding:0 16px;font-size:14px">发送</button>' +
          '</div></div>';
      document.body.appendChild(ov);
      var close = function () { if (ov.parentNode) { ov.parentNode.removeChild(ov); } };
      ov.addEventListener('click', function (e) { if (e.target === ov || e.target.id === 'fcClose') { close(); } });
      function loadComments() {
        api('/feed/comments?id=' + encodeURIComponent(item.id)).then(function (d) {
          var list = d.comments || [];
          document.getElementById('fcTitle').textContent = '评论 ' + (d.count || list.length);
          document.getElementById('fcList').innerHTML = list.length
            ? list.map(function (c) {
                return '<div style="padding:7px 0;border-bottom:1px solid #f5f5f5">' +
                  '<b>' + esc(c.name) + '</b>：' + esc(c.text) + '</div>';
              }).join('')
            : '<div style="color:#999;padding:10px 0">还没有评论，来说第一句</div>';
        }).catch(function (e) { document.getElementById('fcList').textContent = e.message || '加载失败'; });
      }
      loadComments();
      document.getElementById('fcSend').addEventListener('click', function () {
        var input = document.getElementById('fcInput');
        var text = (input.value || '').trim();
        if (!text) { return; }
        api('/feed/comment', { method: 'POST', body: JSON.stringify({ id: item.id, text: text }) }).then(function (d) {
          item.comments = d.comments;
          var badge = document.querySelector('[data-cmt="' + k + '"] span:last-child');
          if (badge) { badge.textContent = d.comments; }
          input.value = '';
          loadComments();
        }).catch(function (err) { toast(err.message); });
      });
    }
      if (!feed.length) { box.innerHTML = '<div class="feed-empty">还没有视频<br>点右上角 ＋ 发一条</div>'; return; }
      box.innerHTML = feed.map(function (v, i) { return feedItemHtml(v, i); }).join('');
      bindFeedProgress();
      var vids = box.querySelectorAll('video');
      function playVisible() {
        Array.prototype.forEach.call(vids, function (v) {
          var r = v.parentNode.getBoundingClientRect();
          if (r.top > -r.height / 2 && r.top < r.height / 2) { v.play().catch(function () { }); }
          else { v.pause(); }
        });
      }
      box.addEventListener('scroll', function () {
        clearTimeout(box._t); box._t = setTimeout(playVisible, 120);
        /* 还剩不到两条就到头 → 拉下一批 */
        if (box.scrollTop + box.clientHeight >= box.scrollHeight - box.clientHeight * 2) { loadMoreChannels(); }
      });
      setTimeout(playVisible, 100);
      /* 手机上浏览器不允许自动出声：点一下画面开声音 */
      box.addEventListener('click', function (e) {
        var v = e.target.closest ? e.target.closest('.feed-item') : null;
        var video = v ? v.querySelector('video') : null;
        if (video && !e.target.closest('button')) {
          video.muted = !video.muted;
          video.play().catch(function () { });
          if (!video.muted) toast('已打开声音');
        }
      });
    }
    $('chBack').addEventListener('click', function () {
      var v = $('feedList').querySelector('video'); if (v) v.pause();
      $('channelsScreen').hidden = true;
    });
    $('feedList').addEventListener('click', function (e) {
      var like = e.target.closest('[data-like]');
      var cmt = e.target.closest('[data-cmt]');
      var share = e.target.closest('[data-share]');
      if (like) {
        var i = Number(like.getAttribute('data-like'));
        api('/feed/like', { method: 'POST', body: JSON.stringify({ id: feed[i].id }) }).then(function (d) {
          feed[i].liked = d.liked; feed[i].likes = d.likes;
          like.querySelector('span:last-child').textContent = d.likes;
          like.querySelector('.fd-ico').style.color = d.liked ? '#ff4d6d' : '#fff';
        }).catch(function (err) { toast(err.message); });
        return;
      }
      if (cmt) {
        var k = Number(cmt.getAttribute('data-cmt'));
        openFeedComments(k);
        return;
      }
      var fav = e.target.closest ? e.target.closest('[data-fav]') : null;
      if (fav) {
        var fi = Number(fav.getAttribute('data-fav'));
        api('/feed/favorite', { method: 'POST', body: JSON.stringify({ id: feed[fi].id }) }).then(function (d) {
          feed[fi].favorited = d.favorited; feed[fi].favorites = d.favorites;
          var ico = fav.querySelector('span:first-child'), num = fav.querySelector('span:last-child');
          if (ico) { ico.style.color = d.favorited ? '#ffc542' : '#fff'; ico.style.background = 'rgba(0,0,0,' + (d.favorited ? '.34' : '.22') + ')'; }
          if (num) { num.textContent = d.favorites; }
          toast(d.favorited ? '已收藏' : '已取消收藏');
        }).catch(function (err) { toast(err.message); });
        return;
      }
      var epBtn = e.target.closest ? e.target.closest('[data-ep]') : null;
      if (epBtn) {
        openEpisodeSheet(Number(epBtn.getAttribute('data-ep')));
        return;
      }
      if (share) {
        var s = Number(share.getAttribute('data-share'));
        var url = location.origin + feed[s].video;
        if (navigator.clipboard) navigator.clipboard.writeText(url).then(function () { toast('链接已复制'); });
        else toast(url);
      }
    });
    /* 发表视频：选文件 → 上传 → 选要不要剪水印 → 发表 */
    $('chPublish').addEventListener('click', function () { $('chFile').click(); });
    $('chFile').addEventListener('change', function (e) {
      var f = e.target.files && e.target.files[0];
      if (!f) return;
      $('chFile').value = '';
      if (f.size > 20 * 1024 * 1024) { toast('视频别超过 20MB（手机上用 App 发会自动压缩）'); return; }
      toast('上传中…');
      var reader = new FileReader();
      reader.onload = function () {
        api('/upload', { method: 'POST', body: JSON.stringify({ dataUrl: String(reader.result), filename: f.name }) })
          .then(function (up) {
            sheet([
              { label: '不处理水印', run: function () { askPublish(up.url); } },
              { label: '剪掉底部 10%', run: function () { doTrim(up.url, { bottom: 0.10 }); } },
              { label: '剪掉底部 14%', run: function () { doTrim(up.url, { bottom: 0.14 }); } },
              { label: '剪掉右侧 12%', run: function () { doTrim(up.url, { right: 0.12 }); } },
              { label: '剪掉右下角', run: function () { doTrim(up.url, { bottom: 0.12, right: 0.10 }); } }
            ]);
          })
          .catch(function (err) { toast(err.message || '上传失败'); });
      };
      reader.readAsDataURL(f);
    });
    function doTrim(url, area) {
      toast('正在剪…');
      api('/feed/trim', { method: 'POST', body: JSON.stringify(Object.assign({ url: url, fill: true }, area)) })
        .then(function (d) { askPublish(d.url); })
        .catch(function (e) { toast(e.message || '剪失败'); askPublish(url); });
    }
    function askPublish(url) {
      var desc = prompt('说点什么…', '分享一条视频');
      if (desc === null) return;
      api('/feed/publish', { method: 'POST', body: JSON.stringify({ video: url, desc: desc }) })
        .then(function () { toast('发表成功'); openChannels(); })
        .catch(function (e) { toast(e.message || '发表失败'); });
    }

    /* ---------------- 直播专场 ---------------- */
    function openLive() {
      $('liveScreen').hidden = false;
      api('/live').then(function (d) { liveRooms = d.rooms || []; renderLive(); })
        .catch(function (e) { toast(e.message || '加载失败'); });
    }
    function renderLive() {
      var box = $('liveList');
      if (!liveRooms.length) { box.innerHTML = '<div class="feed-empty">还没有直播间</div>'; return; }
      box.innerHTML = liveRooms.map(function (r, i) {
        return '<div class="lv-card" data-room="' + i + '">' +
          '<div class="lv-cover"><span class="lv-badge' + (r.status === 'live' ? '' : ' soon') + '">' + (r.status === 'live' ? '直播中' : '预告') + '</span>' +
            (r.tag ? '<span class="lv-tag">' + esc(r.tag) + '</span>' : '') +
            (r.status === 'live' ? '<span class="lv-watch">' + (r.watching || 0) + ' 人在看</span>' : '') + '</div>' +
          '<div class="lv-main"><div class="lv-face">' + (r.host.avatar ? '<img src="' + esc(r.host.avatar) + '" alt="">' : esc(initials(r.host.name))) + '</div>' +
            '<div><div class="lv-title">' + esc(r.title) + '</div><div class="lv-sub">' + esc(r.host.name) + (r.status === 'live' ? ' · ' + (r.hot || 0) + ' 热度' : ' · 待开播') + '</div></div></div></div>';
      }).join('');
    }
    $('liveList').addEventListener('click', function (e) {
      var card = e.target.closest('[data-room]'); if (!card) return;
      enterRoom(liveRooms[Number(card.getAttribute('data-room'))]);
    });
    $('liveBack').addEventListener('click', function () { $('liveScreen').hidden = true; });
    function enterRoom(r) {
      liveRoom = r;
      $('liveRoomScreen').hidden = false;
      $('liveRoomTitle').textContent = r.title;
      $('liveDanmaku').innerHTML = '';
      api('/live/' + r.id + '/join', { method: 'POST' }).then(function (d) {
        $('liveRoomCount').textContent = d.watching + ' 人在看';
      }).catch(function () { });
      addDanmaku('系统', '欢迎来到「' + r.title + '」，友善聊天哦～');
    }
    function addDanmaku(who, text) {
      var box = $('liveDanmaku');
      var el = document.createElement('div');
      el.className = 'dm';
      el.innerHTML = '<b>' + esc(who) + '</b><span>' + esc(text) + '</span>';
      box.appendChild(el);
      while (box.children.length > 9) box.removeChild(box.firstChild);
    }
    window.mmAddDanmaku = addDanmaku;
    $('liveRoomBack').addEventListener('click', function () {
      if (liveRoom) api('/live/' + liveRoom.id + '/leave', { method: 'POST' }).catch(function () { });
      liveRoom = null;
      $('liveRoomScreen').hidden = true;
    });
    $('liveSend').addEventListener('click', function () {
      if (!liveRoom) return;
      var t = $('liveInput').value.trim();
      if (!t) return;
      $('liveInput').value = '';
      api('/live/' + liveRoom.id + '/danmaku', { method: 'POST', body: JSON.stringify({ text: t }) })
        .catch(function (e) { toast(e.message || '发不出去'); });
    });
    $('liveLike').addEventListener('click', function () {
      if (!liveRoom) return;
      api('/live/' + liveRoom.id + '/like', { method: 'POST' }).then(function (d) {
        toast('❤️ ' + d.likes);
      }).catch(function () { });
    });

    /* ---------------- 游戏 ---------------- */
    /* 我 → 作品：三列方块网格，点开全屏播 */
    function openWorks() {
      $('worksScreen').hidden = false;
      $('worksGrid').innerHTML = '<div class="feed-empty" style="grid-column:1/-1">正在加载…</div>';
      /* 「作品」只放自己发布的（别人的作品在视频号里刷） */
      api('/feed?mine=1').then(function (d) {
        var list = d.items || [];
        if (!list.length) { $('worksGrid').innerHTML = '<div class="feed-empty" style="grid-column:1/-1">还没有作品</div>'; return; }
        $('worksGrid').innerHTML = list.map(function (v, i) {
          return '<div class="wk-cell" data-wk="' + i + '">' +
            (v.cover ? '<img src="' + esc(v.cover) + '" alt="" loading="lazy">' : '<div class="wk-play">▶</div>') +
            '<div class="wk-meta">▶ ' + (v.likes || 0) + (v.mine ? '<span class="wk-mine">我的</span>' : '') + '</div></div>';
        }).join('');
        window.__mmWorks = list;
      }).catch(function (e) {
        $('worksGrid').innerHTML = '<div class="feed-empty" style="grid-column:1/-1">' + esc(e.message || '加载失败') + '</div>';
      });
    }
    $('worksBack').addEventListener('click', function () { $('worksScreen').hidden = true; });
    $('worksGrid').addEventListener('click', function (e) {
      var c = e.target.closest('[data-wk]'); if (!c) return;
      var v = (window.__mmWorks || [])[Number(c.getAttribute('data-wk'))];
      if (!v || !v.video) { toast('这条没有视频'); return; }
      $('gamePlayScreen').hidden = false;
      var el = $('playVideo');
      el.src = v.video;
      el.play().catch(function () { });
    });
    $('gamePlayBack').addEventListener('click', function () {
      var el = $('playVideo');
      el.pause(); el.removeAttribute('src'); el.load();
      $('gamePlayScreen').hidden = true;
    });

    function openGames() {
      $('gamesScreen').hidden = false;
      api('/games').then(function (d) { games = d.items || []; renderGames(); })
        .catch(function () { games = []; renderGames(); });
    }
    $('gamesBack').addEventListener('click', function () { $('gamesScreen').hidden = true; });
    function renderGames() {
      var box = $('gamesList');
      if (!games.length) { box.innerHTML = '<div class="feed-empty">还没有游戏</div>'; return; }
      box.innerHTML = games.map(function (g, i) {
        return '<div class="gm-card" data-game="' + i + '"><div class="gm-ico">' + esc(g.icon || '🎮') + '</div>' +
          '<div class="gm-name">' + esc(g.label || '') + '</div><div class="gm-desc">' + esc(g.desc || '') + '</div></div>';
      }).join('');
    }
    $('gamesList').addEventListener('click', function (e) {
      var c = e.target.closest('[data-game]'); if (!c) return;
      playGame(games[Number(c.getAttribute('data-game'))]);
    });
    function playGame(g) {
      var kind = g.kind || 'dice';
      var big = '🎲', res = '';
      var roll = function () {
        if (kind === 'rps') {
          var mine = ['石头', '剪刀', '布'][Math.floor(Math.random() * 3)];
          var cpu = ['石头', '剪刀', '布'][Math.floor(Math.random() * 3)];
          big = mine === '石头' ? '✊' : (mine === '剪刀' ? '✌️' : '✋');
          res = '我出' + mine + '，对方出' + cpu + ' —— ' + (mine === cpu ? '平局' : ((mine === '石头' && cpu === '剪刀') || (mine === '剪刀' && cpu === '布') || (mine === '布' && cpu === '石头') ? '我赢了 🎉' : '我输了'));
        } else if (kind === 'fortune') {
          var list = ['大吉：今天适合出门走走', '中吉：做事顺，但别太急', '小吉：慢慢来，会好', '平：宜喝杯奶茶', '小凶：少熬夜', '大凶：今天别发誓 🤭'];
          big = '🎋'; res = list[Math.floor(Math.random() * list.length)];
        } else if (kind === 'wheel') {
          var picks = ['火锅', '烧烤', '日料', '麻辣烫', '汉堡', '随便点'];
          big = '🎡'; res = '就吃：' + picks[Math.floor(Math.random() * picks.length)];
        } else {
          var n = 1 + Math.floor(Math.random() * 6);
          big = ['⚀', '⚁', '⚂', '⚃', '⚄', '⚅'][n - 1]; res = '掷出了 ' + n + ' 点';
        }
        show(res);
      };
      function show(text) {
        toast((g.icon || '🎮') + ' ' + (text || '点下面开始'));
        sheet([
          { label: text ? '再来一次' : '开始', run: roll },
          {
            label: '发到聊天',
            run: function () {
              if (!res) { toast('先玩一把'); return; }
              sheet((S.chats || []).slice(0, 8).map(function (c) {
                return {
                  label: c.title,
                  run: function () {
                    chatWith(c.id).then(function () { sendText((g.icon || '🎮') + ' ' + res); });
                  }
                };
              }));
            }
          }
        ]);
      }
      show('');
    }

    $('shakeBack').addEventListener('click', function () { $('shakeScreen').hidden = true; });
    $('shakeBtn').addEventListener('click', doShake);
    function openShake() {
      $('shakeScreen').hidden = false;
      renderShake(null, '摇一摇，找到同时在摇手机的人');
      armShake();          // 手机上：真摇手机就触发（第一次会问体感权限）
    }
    /* 网页版真摇手机：devicemotion。iOS 13+ 要先在这句「用户手势」里申请权限。 */
    var shakeArmed = false, shakeLastAt = 0;
    function armShake() {
      if (shakeArmed || typeof DeviceMotionEvent === 'undefined') return;
      var bind = function () {
        window.addEventListener('devicemotion', function (e) {
          var a = e.accelerationIncludingGravity || e.acceleration;
          if (!a) return;
          var mag = Math.sqrt((a.x || 0) * (a.x || 0) + (a.y || 0) * (a.y || 0) + (a.z || 0) * (a.z || 0));
          var thresh = e.accelerationIncludingGravity ? 26 : 3.2;   // 含重力静止约 9.8
          var now = Date.now();
          if (mag > thresh && now - shakeLastAt > 1200) { shakeLastAt = now; doShake(); }
        });
        shakeArmed = true;
      };
      if (typeof DeviceMotionEvent.requestPermission === 'function') {
        DeviceMotionEvent.requestPermission().then(function (r) {
          if (r === 'granted') bind(); else toast('没给「运动与方向」权限，点下面的按钮也能摇');
        }).catch(function () { });
      } else {
        bind();
      }
    }
    function renderShake(person, tipText) {
      var body = $('shakeBody');
      if (!person) {
        body.innerHTML = '<div class="sk-hand"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M6.6 2.4c.5 0 1 .3 1.2.8l1.5 3.3c.2.5.1 1.1-.3 1.5l-1.3 1.3c1 2 2.6 3.6 4.6 4.6l1.3-1.3c.4-.4 1-.5 1.5-.3l3.3 1.5c.5.2.8.7.8 1.2v3.2c0 .8-.6 1.5-1.4 1.6-.6.1-1.2.1-1.9.1C9.7 19.9 4.1 14.3 3.3 6.6c-.1-.7-.1-1.3 0-1.9.1-.8.8-1.4 1.6-1.4h1.7z"/></svg></div>' +
          '<div class="sk-tip">' + esc(tipText) + '</div>';
        $('shakeBtn').textContent = '摇 一 摇';
        return;
      }
      var face = person.avatar ? '<img src="' + esc(person.avatar) + '" alt="" loading="lazy">' : esc(initials(person.nickname));
      var km = (person.km == null) ? '' : (person.km < 1 ? Math.max(100, Math.ceil(person.km * 10) * 100) + '米以内' : person.km.toFixed(1) + '公里以内');
      var sub = person.moodText || person.bio || person.region || '';
      body.innerHTML = '<div class="sk-card">' +
        '<div class="sk-face">' + face + '</div>' +
        '<div class="sk-name">' + esc(person.nickname || '某人') + '</div>' +
        (km ? '<div class="sk-sub">' + esc(km) + '</div>' : '') +
        (sub ? '<div class="sk-sub">' + esc(sub) + '</div>' : '') +
        '<div class="sk-acts">' +
          '<button class="sk-go" data-uid="' + esc(person.id) + '" data-name="' + esc(person.nickname || '') + '" type="button">打招呼</button>' +
          '<button class="sk-see" data-card="' + esc(person.id) + '" type="button">看资料</button>' +
        '</div></div>';
      $('shakeBtn').textContent = '再摇一次';
    }
    function doShake() {
      var go = function (pos) {
        api('/shake', { method: 'POST', body: JSON.stringify(pos ? { lat: pos.lat, lng: pos.lng } : {}) })
          .then(function (d) {
            $('shakeCount').textContent = (d.shaking > 1 ? d.shaking + ' 人在摇' : '');
            if (d.matched) {
              if (navigator.vibrate) navigator.vibrate(40);
              renderShake(d.matched, '');
            } else {
              renderShake(null, '没摇到人，再摇一摇试试（要有别人也在摇才能摇到）');
            }
          })
          .catch(function (e) { renderShake(null, e.message || '摇失败了'); });
      };
      if (nearbyPos) { go(nearbyPos); return; }
      if (!navigator.geolocation) { go(null); return; }
      navigator.geolocation.getCurrentPosition(function (p) {
        nearbyPos = { lat: p.coords.latitude, lng: p.coords.longitude };
        go(nearbyPos);
      }, function () { go(null); }, { timeout: 6000, maximumAge: 60000 });
    }
    if ($('shakeBody')) $('shakeBody').addEventListener('click', function (e) {
      var go = e.target.closest('[data-uid]');
      var see = e.target.closest('[data-card]');
      if (go) {
        var say = prompt('给「' + (go.getAttribute('data-name') || '这个人') + '」打个招呼', '摇一摇摇到你了，交个朋友吧');
        if (say === null) return;
        api('/nearby/hello', { method: 'POST', body: JSON.stringify({ userId: go.getAttribute('data-uid'), text: say }) })
          .then(function (d) { toast('已打招呼'); return loadChats().then(function () { $('shakeScreen').hidden = true; openChat(d.chatId); }); })
          .catch(function (err) { toast(err.message || '发送失败'); });
        return;
      }
      if (see) { toast('点聊天里那条消息可以看资料'); }
    });
    $('nearbyMore').addEventListener('click', function () {
      sheet([
        { label: '全部' + (nearbyGender === 'all' ? '　✓' : ''), run: function () { nearbyGender = 'all'; loadNearby(); } },
        { label: '只看女生' + (nearbyGender === 'female' ? '　✓' : ''), run: function () { nearbyGender = 'female'; loadNearby(); } },
        { label: '只看男生' + (nearbyGender === 'male' ? '　✓' : ''), run: function () { nearbyGender = 'male'; loadNearby(); } },
        { label: '刷新', run: function () { nearbyPos = null; loadNearby(); } },
        {
          label: '清除位置信息并退出',
          run: function () {
            api('/nearby', { method: 'DELETE' }).then(function () {
              toast('已清除位置信息');
              $('nearbyScreen').hidden = true;
            }).catch(function (e) { toast(e.message || '清除失败'); });
          }
        }
      ]);
    });
    $('nearbyList').addEventListener('click', function (e) {
      var row = e.target.closest ? e.target.closest('[data-uid]') : null;
      if (!row) return;
      var id = row.getAttribute('data-uid');
      var name = row.getAttribute('data-name') || '这个人';
      var say = prompt('给「' + name + '」打个招呼', '你好呀，我是在附近的人里看到你的');
      if (say === null) return;
      api('/nearby/hello', { method: 'POST', body: JSON.stringify({ userId: id, text: say }) })
        .then(function (d) {
          toast('已打招呼');
          return loadChats().then(function () { openChat(d.chatId); });
        })
        .catch(function (err) { toast(err.message || '发送失败'); });
    });
    $('requestList').addEventListener('click', function (e) {
      var a = e.target.closest('[data-accept]');
      var r = e.target.closest('[data-reject]');
      if (a) { respondRequest(a.getAttribute('data-accept'), true); return; }
      if (r) { respondRequest(r.getAttribute('data-reject'), false); return; }
    });
    /* ---------------- 我（照着参考图重做后的那一页） ---------------- */
    /* 我页下面的行全部由后台配置渲染（/api/me-page），点了按 action 决定去哪 */
    $('meList').addEventListener('click', function (e) {
      var row = e.target.closest ? e.target.closest('[data-me]') : null;
      if (!row) return;
      var it = (S.mePage || [])[Number(row.getAttribute('data-me'))];
      if (!it) return;
      switch (it.action) {
        case 'service':
          openServicePage();          // 真的「服务」页（照参考图做的）
          break;
        case 'favorites': openFavorites(); break;
        case 'moments': openMoments(S.me && S.me.id); break;
        case 'works': openWorks(); break;
        case 'stickers': openStickers(); break;
        case 'settings': openSettingsPage(); break;
        default: toast(it.label + '：还没做，排在下一批');
      }
    });
    $('momentsBack').addEventListener('click', function () {
      $('momentsScreen').hidden = true;
      S.momentsUser = null; S.momentsTarget = null;     // 退出后回到「大家的朋友圈」
    });
    $('momentsScroll').addEventListener('scroll', function () {
      syncMomentsTitle();
      var sc = $('momentsScroll');
      if (!sc) return;
      if (sc.scrollHeight - sc.scrollTop - sc.clientHeight < 500) loadMoreMoments();
    }, { passive: true });
    $('chipMoments').addEventListener('click', function () { openMoments(S.me.id); });
    $('chipStatus').addEventListener('click', openStatusPage);
    /* 点语音气泡就播（网页版以前只显示一行「🎤 语音」，点了没反应） */
    var voiceAudio = null, voiceBubble = null;
    $('messages').addEventListener('click', function (e) {
      var v = e.target.closest ? e.target.closest('.wx-voice') : null;
      if (!v) return;
      var src = v.getAttribute('data-voice');
      if (!src) { toast('这条语音找不到了'); return; }
      if (voiceBubble === v && voiceAudio && !voiceAudio.paused) {
        voiceAudio.pause(); voiceAudio.currentTime = 0;
        v.classList.remove('is-playing'); voiceBubble = null; return;
      }
      if (voiceAudio) { voiceAudio.pause(); if (voiceBubble) voiceBubble.classList.remove('is-playing'); }
      voiceAudio = new Audio(src);
      voiceBubble = v;
      v.classList.add('is-playing');
      voiceAudio.onended = function () { v.classList.remove('is-playing'); voiceBubble = null; };
      voiceAudio.onerror = function () { v.classList.remove('is-playing'); toast('语音播放失败'); };
      voiceAudio.play().catch(function () { v.classList.remove('is-playing'); toast('语音播放失败'); });
    });
    $('meQr').addEventListener('click', openProfile);
    $('stkBack').addEventListener('click', function () { $('stickerScreen').hidden = true; });
    $('stkPacks').addEventListener('click', function (e) {
      var tab = e.target.closest('.stk-tab'); if (!tab) return;
      S.stickerTab = Number(tab.getAttribute('data-pack'));
      renderStickers();
    });
    $('stkGrid').addEventListener('click', function (e) {
      var cell = e.target.closest('.stk-cell'); if (!cell) return;
      var img = cell.getAttribute('data-img');
      if (img) { sendSticker(null, img); return; }
      sendSticker(cell.getAttribute('data-txt') || '', null);
    });
    $('stkSearch').addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); searchStickers(); } });
    $('setBack').addEventListener('click', function () { $('settingsScreen').hidden = true; });
    if ($('setSearch')) $('setSearch').addEventListener('input', function () { renderSettingsPage($('setSearch').value.trim()); });

    /* ---------------- 服务页：返回 / ⋯ / 点格子 ---------------- */
    $('svcBack').addEventListener('click', function () { $('serviceScreen').hidden = true; });
    $('svcMore').addEventListener('click', function () {
      sheet([
        { label: '手机访问', run: openPhoneInfo },
        { label: '安全中心', run: openSecurityInfo },
        { label: '切换外观', run: openThemeSheet }
      ]);
    });
    $('svcList').addEventListener('click', function (e) {
      var el = e.target.closest ? e.target.closest('[data-svc]') : null;
      if (!el) return;
      var kind = el.getAttribute('data-svc');
      if (kind === 'card') { runServiceAction(el.getAttribute('data-act'), ''); return; }
      var groups = ((S.service || {}).groups) || [];
      var g = groups[Number(el.getAttribute('data-g'))];
      var it = g && (g.items || [])[Number(el.getAttribute('data-i'))];
      if (!it) return;
      runServiceAction(it.action, it.label);
    });

    /* ---------------- 钱包页：返回 / 右上角「账单」/ 点行 / 底部链接 ---------------- */
    $('waBack').addEventListener('click', function () { $('walletScreen').hidden = true; });
    $('waRight').addEventListener('click', function () { runWalletAction('bills', '账单'); });
    $('waList').addEventListener('click', function (e) {
      /* 点金额：藏着的话点一下看，看着的时候点一下再藏起来（不触发这一行的动作） */
      var val = e.target.closest ? e.target.closest('.wa-value[data-mask="1"]') : null;
      if (val) {
        e.stopPropagation();
        var id = val.getAttribute('data-id');
        S.walletShown = S.walletShown || {};
        if (S.walletShown[id]) delete S.walletShown[id]; else S.walletShown[id] = true;
        paintWallet();
        return;
      }
      var row = e.target.closest ? e.target.closest('[data-wa="item"]') : null;
      if (!row) return;
      var groups = ((S.wallet || {}).groups) || [];
      var g = groups[Number(row.getAttribute('data-g'))];
      var it = g && (g.items || [])[Number(row.getAttribute('data-i'))];
      if (!it) return;
      runWalletAction(it.action, it.label);
    });
    $('waFoot').addEventListener('click', function (e) {
      var btn = e.target.closest ? e.target.closest('[data-wa="foot"]') : null;
      if (!btn) return;
      var list = ((S.wallet || {}).footer) || [];
      var it = list[Number(btn.getAttribute('data-i'))];
      if (!it) return;
      runWalletAction(it.action, it.label);
    });

    /* ---------------- 账单页：返回 / ⋯ / 筛选 / 查找 / 收支统计 / 选月份 / 点一条看详情 ---------------- */
    $('bllBack').addEventListener('click', function () { $('billListScreen').hidden = true; });
    $('bllMore').addEventListener('click', function () {
      sheet([
        { label: '账单常见问题', run: openBillsFaq },
        { label: '导出账单（CSV）', run: exportBillsCsv }
      ]);
    });
    $('bllFilter').addEventListener('click', function () {
      sheet([
        { label: '全部账单', run: function () { S.billFilter = 'all'; paintBills(); } },
        { label: '只看支出', run: function () { S.billFilter = 'out'; paintBills(); } },
        { label: '只看收入', run: function () { S.billFilter = 'in'; paintBills(); } }
      ]);
    });
    $('bllStats').addEventListener('click', function () {
      var sum = ((S.billsData || {}).summary) || {};
      var m = (S.billsData || {}).month || '';
      sheet([
        { label: (m ? (m.slice(0, 4) + '年' + Number(m.slice(5, 7)) + '月') : '全部') + '支出 ' + money(sum.out || 0), run: function () { } },
        { label: '收入 ' + money(sum.in || 0) + '（只算已收款的）', run: function () { } },
        { label: '待你收款 ' + (sum.pendingIn || 0) + ' 笔 · 待对方收款 ' + (sum.pendingOut || 0) + ' 笔', run: function () { } },
        { label: '一共 ' + (sum.count || 0) + ' 笔', run: function () { } }
      ]);
    });
    $('bllQuery').addEventListener('input', function () {
      S.billQuery = $('bllQuery').value || '';
      paintBills();
    });
    function pickMonth() {
      var months = ((S.billsData || {}).months) || [];
      var opts = [{ label: '全部账单', run: function () { loadBillsPage(''); } }];
      months.forEach(function (m) {
        opts.push({ label: m.slice(0, 4) + '年' + Number(m.slice(5, 7)) + '月', run: function () { loadBillsPage(m); } });
      });
      sheet(opts);
    }
    $('bllList').addEventListener('click', function (e) {
      var mp = e.target.closest ? e.target.closest('[data-monthpick]') : null;
      if (mp) { pickMonth(); return; }
      var row = e.target.closest ? e.target.closest('[data-bill]') : null;
      if (!row) return;
      openBillDetail(row.getAttribute('data-bill'));
    });

    /* ---------------- 零钱页：返回 / 充值 / 提现 / 底部链接 ---------------- */
    $('coinBack').addEventListener('click', function () { $('coinScreen').hidden = true; });
    $('coinRecharge').addEventListener('click', function () { runCoinAction((S.coinPage || {}).recharge ? S.coinPage.recharge.action : 'recharge', '充值'); });
    $('coinWithdraw').addEventListener('click', function () { runCoinAction((S.coinPage || {}).withdraw ? S.coinPage.withdraw.action : 'withdraw', '提现'); });
    $('coinLinks').addEventListener('click', function (e) {
      var btn = e.target.closest ? e.target.closest('[data-coinlink]') : null;
      if (!btn) return;
      var list = ((S.coinPage || {}).links) || [];
      var it = list[Number(btn.getAttribute('data-coinlink'))];
      if (it) runCoinAction(it.action, it.label);
    });

    function openPhoneInfo() {
      api('/lan').then(function (d) {
        var u = (d.urls || [])[0];
        sheet([{ label: u ? u.url : '没有局域网地址', run: function () { } }]);
      }).catch(function () { toast('读取失败'); });
    }
    function openSecurityInfo() {
      openSecurityCenter(false);
    }
    function openTransferLimitInfo() {
      api('/me').then(function (d) {
        var u = (d && d.user) || {};
        var lim = Number(u.transferLimit) || 0;
        var bal = Number(u.balance) || 0;
        sheet([
          { label: lim > 0 ? ('单笔最多 ¥' + lim.toFixed(2)) : '单笔不限额度', run: function () { } },
          { label: '当前余额 ¥' + bal.toFixed(2), run: function () { } },
          { label: '限额由管理员在后台「用户管理」里设置', run: function () { } }
        ]);
      }).catch(function () { toast('读取失败'); });
    }
    function openThemeSheet() {
      sheet([
        { label: '深色（和微信一致）', run: function () { applyTheme('dark'); } },
        { label: '浅色', run: function () { applyTheme('light'); } }
      ]);
    }
    function openStatusSheet() {
      sheet([
        { label: '🟢 在线', run: function () { setStatus('online'); } },
        { label: '💼 忙碌', run: function () { setStatus('busy'); } },
        { label: '🌙 离开', run: function () { setStatus('away'); } },
        { label: '👻 隐身（好友看你离线）', run: function () { setStatus('invisible'); } }
      ]);
    }
    function setStatus(st) {
      api('/me/status', { method: 'POST', body: JSON.stringify({ status: st }) })
        .then(function () {
          if (S.me) S.me.status = st;
          toast({ online: '已设为在线', busy: '已设为忙碌', away: '已设为离开', invisible: '已设为隐身' }[st] || '状态已更新');
        })
        .catch(function (e) { toast(e.message || '设置失败'); });
    }
    function openSettingsSheet() {
      sheet([
        { label: '个人信息（头像 / 名字 / 性别）', run: openProfile },
        { label: '外观：深色 / 浅色', run: openThemeSheet },
        { label: '手机访问地址', run: openPhoneInfo },
        { label: '安全中心', run: openSecurityInfo },
        { label: '退出登录', run: function () { sheet([{ label: '确认退出登录', run: doLogout }]); } }
      ]);
    }

    /* ---------------- 设置页（照着参考图做的整页） ---------------- */
    var SET_ROWS = [
      { g: 1, id: 'setProfile', label: '个人资料', run: function () { $('settingsScreen').hidden = true; openProfile(); } },
      { g: 1, id: 'setAccount', label: '账号与安全', run: openSecurityInfo },
      { g: 1, id: 'setTransferLimit', label: '单笔转账限额', value: '查看', run: openTransferLimitInfo },
      { g: 1, id: 'setPrivacy', label: '个人信息与权限', run: function () { toast('个人信息与权限：目前只用来做安全评分'); } },
      { g: 2, id: 'setNotify', label: '通知', value: '提示音', run: openNotifySheet },
      { g: 2, id: 'setDisplay', label: '界面与显示', run: openThemeSheet },
      { g: 2, id: 'setFriendPerm', label: '朋友权限', run: function () { toast('朋友权限：默认所有好友都能看你的朋友圈'); } },
      { g: 3, id: 'setStorage', label: '存储空间', value: '本机', run: openStorageInfo },
      { g: 3, id: 'setMore', label: '更多', run: function () { toast('更多设置还在补，先按参考图把位置留好'); } },
      { g: 4, id: 'setChat', label: '聊天', run: openPhoneInfo },
      { g: 4, id: 'setCall', label: '音视频通话', run: function () { toast('音视频通话请用电脑版，手机端可看聊天页顶部按钮'); } },
      { g: 4, id: 'setHistory', label: '聊天记录管理', run: function () { toast('聊天记录都在服务器上，手机端不做本地清理'); } }
    ];

    function openSettingsPage() {
      renderSettingsPage('');
      $('settingsScreen').hidden = false;
      if ($('setSearch')) $('setSearch').value = '';
    }


    function renderSettingsPage(kw) {
      var box = $('setScroll');
      if (!box) return;
      var list = SET_ROWS.filter(function (r) {
        return !kw || r.label.toLowerCase().indexOf(kw.toLowerCase()) >= 0;
      });
      var html = '', lastG = 0;
      list.forEach(function (r) {
        if (r.g !== lastG) {
          if (lastG) html += '</div>';
          html += '<div class="set-group">';
          lastG = r.g;
        }
        html += '<button class="set-row" id="' + r.id + '">' +
          '<span class="set-label">' + esc(r.label) + '</span>' +
          (r.value ? '<span class="set-value">' + esc(r.value) + '</span>' : '') +
          '<span class="me-arrow">›</span></button>';
      });
      if (lastG) html += '</div>';
      if (!list.length) html = '<div class="wx-empty">没找到相关设置</div>';
      html += '<div style="height:8px"></div><button class="set-red" id="setLogout">退出登录</button>';
      box.innerHTML = html;
      // 绑事件（每次都重建，所以重新绑）
      list.forEach(function (r) {
        var el = $(r.id);
        if (el) el.addEventListener('click', r.run);
      });
      if ($('setLogout')) {
        $('setLogout').addEventListener('click', function () {
          sheet([{ label: '确认退出登录', run: doLogout }]);
        });
      }
    }

    function openNotifySheet() {
      sheet([
        { label: '新消息提示音：开', run: function () { toast('提示音已打开'); } },
        { label: '新消息提示音：关', run: function () { toast('提示音已关闭'); } },
        { label: '振动', run: function () { toast('振动跟随系统设置'); } }
      ]);
    }

    function openStorageInfo() {
      api('/system').catch(function () { return null; }).then(function () {
        toast('缓存都是聊天图片，存在服务器上，不占你手机空间');
      });
    }

    $('chatBack').addEventListener('click', function () {
      if (chatSlideOut) chatSlideOut(closeChat); else closeChat();
    });
    /* 名片页的返回和「更多信息」 */
    $('cardBack').addEventListener('click', closeCard);
    /* ---------------- 腾讯新闻 ---------------- */
    var newsList = [];
    function newsTime(ts) {
      if (!ts) return '';
      var d = new Date(ts);
      var now = new Date();
      var mins = Math.floor((now - d) / 60000);
      if (mins < 1) return '刚刚';
      if (mins < 60) return mins + ' 分钟前';
      if (d.toDateString() === now.toDateString()) return ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2);
      return (d.getMonth() + 1) + '月' + d.getDate() + '日';
    }
    function renderNews() {
      var box = $('newsList');
      box.innerHTML = '<div class="wx-empty">正在加载腾讯新闻…</div>';
      api('/news?limit=20').then(function (d) {
        newsList = d.list || [];
        if (!newsList.length) { box.innerHTML = '<div class="wx-empty">暂时拿不到新闻，下拉刷新试试</div>'; return; }
        box.innerHTML = newsList.map(function (it, i) {
          return '<button class="news-item has-rank' + (i < 3 ? ' is-top' + (i + 1) : '') + '" data-news="' + i + '">' +
            '<span class="news-rank">' + (i + 1) + '</span>' +
            '<span class="news-main">' +
              '<span class="news-title">' + esc(it.title) + '</span>' +
              '<span class="news-meta">' + esc(it.source || '腾讯新闻') + (it.time ? (' · ' + newsTime(it.time)) : '') + '</span>' +
            '</span>' +
            (it.img ? '<img class="news-img" src="' + esc(it.img) + '" alt="" loading="lazy" decoding="async">' : '') +
            '</button>';
        }).join('');
      }).catch(function (e) {
        box.innerHTML = '<div class="wx-empty">' + esc(e.message || '加载失败') + '</div>';
      });
    }
    function openNews() {
      $('newsScreen').hidden = false;
      renderNews();
    }

    /* ---------------- 附近的人 ---------------- */
    function openNearby() {
      $('nearbyScreen').hidden = false;
      loadNearby();
    }
    function loadNearby() {
      var box = $('nearbyList');
      box.innerHTML = '<div class="nb-empty">正在定位…</div>';
      var go = function (pos) {
        nearbyPos = pos;
        /* 进了这个页面 = 「我在附近」，把位置报上去 */
        api('/nearby', { method: 'POST', body: JSON.stringify({ lat: pos.lat, lng: pos.lng }) })
          .catch(function () { });
        api('/nearby?lat=' + pos.lat + '&lng=' + pos.lng + '&gender=' + nearbyGender)
          .then(function (d) { renderNearby(d.people || []); })
          .catch(function (e) { box.innerHTML = '<div class="nb-empty">' + esc(e.message || '加载失败') + '</div>'; });
      };
      if (nearbyPos) { go(nearbyPos); return; }
      if (!navigator.geolocation) { box.innerHTML = '<div class="nb-empty">这个浏览器拿不到定位</div>'; return; }
      navigator.geolocation.getCurrentPosition(function (p) {
        go({ lat: p.coords.latitude, lng: p.coords.longitude });
      }, function () {
        box.innerHTML = '<div class="nb-empty">拿不到定位<br>请在浏览器里允许「位置」权限再进来一次</div>';
      }, { timeout: 8000, maximumAge: 60000 });
    }
    function renderNearby(list) {
      var box = $('nearbyList');
      if (!list.length) {
        box.innerHTML = '<div class="nb-empty">附近还没有人<br>让对方也进一次「附近的人」</div>';
        return;
      }
      box.innerHTML = list.map(function (p) {
        var face = p.avatar
          ? '<img src="' + esc(p.avatar) + '" alt="" loading="lazy" decoding="async">'
          : esc(initials(p.nickname));
        var km = (p.km == null) ? ''
          : (p.km < 1 ? Math.max(100, Math.ceil(p.km * 10) * 100) + '米以内' : p.km.toFixed(1) + '公里以内');
        var bio = p.moodText || p.bio || (p.friend ? '已经是好友' : '');
        return '<div class="nb-row" data-uid="' + esc(p.id) + '" data-name="' + esc(p.nickname || '') + '">' +
          '<div class="nb-face">' + face + '</div>' +
          '<div class="nb-left">' +
            '<div class="nb-name">' + esc(p.nickname || '附近的人') + '</div>' +
            '<div class="nb-km">' + esc(km) + '</div>' +
          '</div>' +
          (bio ? '<div class="nb-sign">' + esc(bio) + '</div>' : '') +
        '</div>';
      }).join('');
    }
    /* 让贾维斯讲讲（把新闻丢给它，它会联网搜 + 总结） */
    function askJarvis(text) {
      var bot = (S.friends || []).filter(function (f) { return f.username === 'housekeeper'; })[0];
      if (!bot) { toast('没找到贾维斯AI'); return; }
      chatWith(bot.id).then(function () {
        setTimeout(function () { sendText(text); }, 600);
      }).catch(function (e) { toast(e.message || '打不开和贾维斯的聊天'); });
    }
    if ($('dscNews')) $('dscNews').addEventListener('click', openNews);
    if ($('newsBack')) $('newsBack').addEventListener('click', function () { $('newsScreen').hidden = true; });
    if ($('newsAsk')) $('newsAsk').addEventListener('click', function () {
      var top = newsList.slice(0, 6).map(function (x, i) { return (i + 1) + '. ' + x.title; }).join('\n');
      askJarvis('帮我讲讲今天腾讯新闻的热点，挑最重要的说，每条一两句话：\n' + (top || '今天有什么热点？'));
    });
    if ($('newsList')) $('newsList').addEventListener('click', function (e) {
      var b = e.target.closest('[data-news]'); if (!b) return;
      var it = newsList[Number(b.getAttribute('data-news'))];
      if (!it) return;
      sheet([
        { label: '让贾维斯讲讲这条', run: function () { askJarvis('帮我讲讲这条新闻：' + it.title + (it.summary ? ('\n（大概内容：' + it.summary.slice(0, 150) + '）') : '')); } },
        { label: '看原文（腾讯新闻）', run: function () { try { window.open(it.url, '_blank'); } catch (err) { location.href = it.url; } } },
        { label: (it.source || '腾讯新闻') + ' · ' + (newsTime(it.time) || ''), run: function () { } }
      ]);
    });
    $('cardMore').addEventListener('click', function () {
      sheet([
        { label: '设置备注和标签', run: function () { toast('备注和标签还没开，先看下面的资料'); } },
        { label: '朋友圈权限', run: function () { toast('默认：能看他的朋友圈'); } }
      ]);
    });
    /* 「朋友资料」那一行：把能看到的资料列出来 */
    $('cdMoreRow').addEventListener('click', function () {
      sheet([
        { label: $('cdNick').textContent, run: function () { } },
        { label: $('cdWx').textContent, run: function () { } },
        { label: $('cdRegion').textContent, run: function () { } }
      ]);
    });
    /* 「朋友圈」那一行（连右边的箭头）：跳到他发的朋友圈 */
    $('cdThumbCard').addEventListener('click', function (e) {
      var thumb = e.target.closest('.cd-thumb img');
      if (thumb) {                                  // 点小图 → 直接看大图
        var all = [].slice.call(document.querySelectorAll('#cdThumbs img')).map(function (i) { return i.getAttribute('src'); });
        openPhotos(all, Math.max(0, all.indexOf(thumb.getAttribute('src'))));
        return;
      }
      var uid = cardUserId;
      if (!uid) return;
      closeCard();
      openMoments(uid);
    });
    /* 「电话」那一行：点一下可以拨 */
    $('cdPhoneRow').addEventListener('click', function () {
      var num = $('cdPhone').textContent || '';
      if (!num || num === '—') return;
      sheet([{ label: '拨打 ' + num, run: function () { try { location.href = 'tel:' + num; } catch (e) { toast(num); } } }]);
    });
    // 聊天里的图片点开也是那个能左右滑的大图（不用跳新窗口）
    $('messages').addEventListener('click', function (e) {
      if (msgMenuJustOpened) { msgMenuJustOpened = false; e.preventDefault(); e.stopPropagation(); return; }
      /* 表情 / ＋ 面板弹着的时候，点一下聊天区域就收回去（和 App 一样） */
      if (($('emojiPanel') && !$('emojiPanel').hidden) ||
          ($('plusPanel') && !$('plusPanel').hidden) ||
          ($('giftPanel') && !$('giftPanel').hidden)) {
        setEmojiOpen(false); setPlusOpen(false);
        if (typeof setGiftOpen === 'function') setGiftOpen(false);
      }
      /* 正在打字的时候点聊天区域：收起系统键盘（和 App 一样） */
      try { if (document.activeElement && document.activeElement.id === 'msgInput') document.activeElement.blur(); } catch (err) { }
      var face = e.target.closest('.wx-msg-avatar');          // 点头像 → 名片
      var link = e.target.closest ? e.target.closest('.wx-link') : null;   // 消息里的链接 → 复制（App 里不好直接跳）
      if (link) {
        e.preventDefault();
        var linkUrl = link.getAttribute('href') || '';
        openOutside(linkUrl);
        return;
      }
      if (face) {
        var fuid = face.getAttribute('data-uid');
        if (fuid) { openCard(fuid); return; }
      }
      var card = e.target.closest('[data-transfer]');
      if (card) { onTransferTap(card, e); return; }
      var rp = e.target.closest('[data-rp]');
      if (rp) { onRedPacketTap(rp.getAttribute('data-rp')); return; }
      var loc = e.target.closest('[data-loc]');
      if (loc) {
        var parts = String(loc.getAttribute('data-loc') || '').split(',');
        openLocationPicker(Number(parts[0]), Number(parts[1]), loc.getAttribute('data-locname') || '');
        return;
      }
      var img = e.target.closest('[data-img]');
      if (!img) return;
      var all = [].slice.call($('messages').querySelectorAll('[data-img]')).map(function (x) { return x.getAttribute('data-img'); });
      var at = all.indexOf(img.getAttribute('data-img'));
      openPhotos(all, at < 0 ? 0 : at);
    });
    $('msgInput').addEventListener('input', updateSendBtn);
    $('msgInput').addEventListener('keydown', function (e) { if (e.key === 'Enter') sendMessage(); });
    $('btnEmoji').addEventListener('click', toggleEmojiPanel);
    $('emojiPages').addEventListener('click', function (e) {
      var cell = e.target.closest('.wx-emoji-cell'); if (!cell) return;
      insertEmoji(cell.getAttribute('data-e'));
    });
    $('emojiPages').addEventListener('scroll', function () { paintEmojiDots(); }, { passive: true });
    $('emojiDel').addEventListener('click', emojiBackspace);
    $('emojiSend').addEventListener('click', function () { sendMessage(); });
    $('msgInput').addEventListener('focus', function () { setEmojiOpen(false); });
    if ($('btnVoice')) {
      $('btnVoice').addEventListener('click', function () { toast('语音请在电脑版或浏览器里用（需要麦克风权限）'); });
    }
    // 输入框右边的喇叭：开关消息提示音
    var speakerOn = true;
    try { speakerOn = localStorage.getItem('wx-speaker') !== '0'; } catch (e) { }
    function paintSpeaker() {
      var btn = $('btnSpeaker');
      if (!btn) return;
      btn.style.opacity = speakerOn ? '1' : '0.45';
      btn.title = speakerOn ? '提示音：开' : '提示音：关';
    }
    if ($('btnSpeaker')) {
      paintSpeaker();
      $('btnSpeaker').addEventListener('click', function () {
        speakerOn = !speakerOn;
        try { localStorage.setItem('wx-speaker', speakerOn ? '1' : '0'); } catch (e) { }
        paintSpeaker();
        toast(speakerOn ? '提示音已打开' : '提示音已关闭');
      });
    }
    $('btnPlus').addEventListener('click', togglePlusPanel);
    $('plusPages').addEventListener('click', function (e) {
      var cell = e.target.closest('.wx-plus-cell'); if (!cell) return;
      plusTap(cell.getAttribute('data-act'), cell.getAttribute('data-label'));
    });
    $('plusPages').addEventListener('scroll', function () { paintPlusDots(); }, { passive: true });
    $('giftPages').addEventListener('click', function (e) {
      var cell = e.target.closest('.wx-gift-cell'); if (!cell) return;
      var g = null;
      try { g = JSON.parse(cell.getAttribute('data-g')); } catch (err) { g = null; }
      sendGift(g);
    });
    $('giftPages').addEventListener('scroll', function () { paintGiftDots(); }, { passive: true });
    $('giftFlood').addEventListener('click', closeGiftFlood);   // 点一下就跳过
    bindPlusFile();
    $('btnNewChat').addEventListener('click', function () { switchTab('contacts'); });
    $('chatMore').addEventListener('click', function () {
      sheet([
        { label: '聊天背景', run: openChatBgSheet },
        { label: '语音通话', run: function () { startCall('audio'); } },
        { label: '视频通话', run: function () { startCall('video'); } },
        { label: '刷新消息', run: function () { openChat(S.activeChat); } },
        { label: '返回会话列表', run: closeChat }
      ]);
    });

    $('momentList').addEventListener('click', function (e) {
      var mFace = e.target.closest('.wx-moment-avatar');       // 点头像 → 名片
      if (mFace) {
        var mUid = mFace.getAttribute('data-uid');
        if (mUid) { openCard(mUid); return; }
      }
      var like = e.target.closest('[data-like]');
      var cmt = e.target.closest('[data-comment]');
      var more = e.target.closest('[data-more]');
      var img = e.target.closest('[data-img]');
      if (more) {
        var mid = more.getAttribute('data-more');
        var mm = S.moments.filter(function (x) { return x.id === mid; })[0] || {};
        openMomentMenu(more, mm);
        return;
      }
      if (like) {
        likeMoment(like.getAttribute('data-like'));
        return;
      }
      if (cmt) {
        commentMoment(cmt.getAttribute('data-comment'));
        return;
      }
      if (img) {
        var box = img.closest('.wx-moment');
        var all = box ? [].slice.call(box.querySelectorAll('[data-img]')).map(function (x) { return x.getAttribute('data-img'); }) : [img.getAttribute('data-img')];
        var at = all.indexOf(img.getAttribute('data-img'));
        openPhotos(all, at < 0 ? 0 : at);
      }
    });

    /* ---------------- 朋友圈大图：左右滑着看 ---------------- */
    function openPhotos(list, index) {
      if (!list || !list.length) return;
      var track = $('phTrack');
      $('phView').hidden = false;            // 先显示出来，量尺寸才准
      track.innerHTML = list.map(function (src) {
        return '<div class="ph-item"><img src="' + esc(src) + '" alt="" decoding="async"></div>';
      }).join('');
      // 长图按屏宽铺满，普通/横图按整屏缩放
      var fitAll = function () {
        var cw = track.clientWidth || window.innerWidth;
        var ch = track.clientHeight || (window.innerHeight * 0.84);
        var screenRatio = ch / Math.max(1, cw);
        [].slice.call(track.querySelectorAll('img')).forEach(function (im) {
          if (!im.naturalWidth) return;
          var tall = (im.naturalHeight / im.naturalWidth) > screenRatio + 0.03;
          im.classList.toggle('is-tall', tall);
          im.classList.toggle('is-wide', !tall);
          if (im.parentNode) im.parentNode.classList.toggle('is-tallimg', tall);
        });
      };
      [].slice.call(track.querySelectorAll('img')).forEach(function (im) {
        if (im.complete) fitAll(); else im.addEventListener('load', fitAll);
      });
      fitAll();
      paintPhotoCount(index || 0, list.length);
      // 等布局好再跳到位
      requestAnimationFrame(function () {
        fitAll();
        track.scrollLeft = (index || 0) * track.clientWidth;
        paintPhotoCount(Math.round(track.scrollLeft / Math.max(1, track.clientWidth)), list.length);
      });
    }

    function paintPhotoCount(i, total) {
      var n = Math.min(total, Math.max(1, i + 1));
      $('phCount').textContent = n + ' / ' + total;
    }

    function closePhotos() { $('phView').hidden = true; $('phTrack').innerHTML = ''; }

    /* 和微信一样：右上角不再放「×」，点一下图片（或画面任意一处）就返回。
       左右滑动看别的图不会误关——滑动过的 400ms 内忽略这次点击。 */
    var phTouchX = 0, phTouchY = 0, phMovedAt = 0;
    $('phView').addEventListener('touchstart', function (e) {
      if (e.touches.length !== 1) { phMovedAt = Date.now(); return; }
      phTouchX = e.touches[0].clientX; phTouchY = e.touches[0].clientY;
    }, { passive: true });
    $('phView').addEventListener('touchmove', function (e) {
      if (e.touches.length !== 1) { phMovedAt = Date.now(); return; }
      if (Math.abs(e.touches[0].clientX - phTouchX) > 8 || Math.abs(e.touches[0].clientY - phTouchY) > 8) phMovedAt = Date.now();
    }, { passive: true });
    $('phView').addEventListener('click', function () {
      if (Date.now() - phMovedAt < 400) return;
      closePhotos();
    });
    $('phTrack').addEventListener('scroll', function () {
      var track = $('phTrack');
      var total = track.children.length;
      var i = Math.round(track.scrollLeft / Math.max(1, track.clientWidth));
      paintPhotoCount(i, total);
    }, { passive: true });
    document.addEventListener('keydown', function (e) {
      if ($('phView').hidden) return;
      var track = $('phTrack');
      if (e.key === 'ArrowRight') track.scrollLeft += track.clientWidth;
      else if (e.key === 'ArrowLeft') track.scrollLeft -= track.clientWidth;
      else if (e.key === 'Escape') closePhotos();
    });

    /* 三点按钮：在按钮左边弹出小气泡（赞 / 评论 / 删除），不再从底部弹 */
    function closeMomentMenu() { $('mmMask').hidden = true; $('mmPop').innerHTML = ''; }

    function openMomentMenu(btn, m) {
      var liked = !!(m && m.likedByMe);
      var mine = !!(m && m.author && S.me && m.author.id === S.me.id);
      var heart = '<svg viewBox="0 0 24 24" fill="' + (liked ? 'currentColor' : 'none') + '" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20.2l-1.2-1.1C6.1 14.9 3.3 12.4 3.3 9.3c0-2.5 2-4.5 4.5-4.5 1.4 0 2.8.7 4.2 2.1 1.4-1.4 2.8-2.1 4.2-2.1 2.5 0 4.5 2 4.5 4.5 0 3.1-2.8 5.6-7.5 9.8L12 20.2z"/></svg>';
      var chat = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20.4 12.2c0 3.7-3.8 6.7-8.4 6.7-.9 0-1.8-.1-2.6-.3l-4 1.8 1.2-3.4C5 15.7 3.6 14.1 3.6 12.2c0-3.7 3.8-6.7 8.4-6.7s8.4 3 8.4 6.7z"/></svg>';
      var trash = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4.6 7.2h14.8M9.4 7.2V5.4h5.2v1.8M6.6 7.2l.9 11.4h9l.9-11.4"/></svg>';
      $('mmPop').innerHTML =
        '<button class="mm-item' + (liked ? ' is-on' : '') + '" data-mm="like">' + heart + (liked ? '取消' : '赞') + '</button>' +
        '<button class="mm-item" data-mm="comment">' + chat + '评论</button>' +
        (mine ? '<button class="mm-item is-danger" data-mm="del">' + trash + '删除</button>' : '');

      var pop = $('mmPop');
      $('mmMask').hidden = false;
      var r = btn.getBoundingClientRect();
      var w = pop.offsetWidth, h = pop.offsetHeight;
      // 贴着按钮左边出来（右边对齐按钮右边），底边跟按钮底边对齐
      var left = Math.max(8, r.right - w);
      var top = r.top - h - 8;
      if (top < 8) top = r.bottom + 8;      // 上面放不下就往下放
      pop.style.left = Math.round(left) + 'px';
      pop.style.top = Math.round(top) + 'px';

      pop.onclick = function (ev) {
        var b = ev.target.closest('[data-mm]'); if (!b) return;
        var act = b.getAttribute('data-mm');
        closeMomentMenu();
        if (act === 'like') likeMoment(m.id);
        else if (act === 'comment') commentMoment(m.id);
        else if (act === 'del') deleteMoment(m.id);
      };
      $('mmMask').onclick = function (ev) { if (ev.target === $('mmMask')) closeMomentMenu(); };
    }

    function likeMoment(id) {
      api('/moments/' + encodeURIComponent(id) + '/like', { method: 'POST' })
        .then(function (d) { applyMoment(d.moment); })
        .catch(function (err) { toast(err.message); });
    }

    /* 评论：直接在底部输入条里打字，跟聊天框一样 */
    var cmtTarget = null;
    function commentMoment(id) {
      cmtTarget = id;
      $('cmtInput').value = '';
      paintCmtSend();
      $('cmtBar').hidden = false;
      setTimeout(function () { try { $('cmtInput').focus(); } catch (e) { } }, 70);
    }
    function paintCmtSend() {
      var on = !!$('cmtInput').value.trim();
      $('cmtSend').classList.toggle('is-on', on);
    }
    function sendComment() {
      var text = $('cmtInput').value.trim();
      if (!text) { paintCmtSend(); return; }      // 空的时候按钮是灰的，点了不做任何事
      var id = cmtTarget;
      closeCommentBar();
      if (!id) return;
      api('/moments/' + encodeURIComponent(id) + '/comments', { method: 'POST', body: JSON.stringify({ content: text }) })
        .then(function (d) { applyMoment(d.moment); toast('评论成功'); })
        .catch(function (err) { toast(err.message); });
    }
    function closeCommentBar() {
      $('cmtBar').hidden = true;
      cmtTarget = null;
      paintCmtSend();
      try { $('cmtInput').blur(); } catch (e) { }
    }
    $('cmtSend').addEventListener('click', sendComment);
    $('cmtInput').addEventListener('input', paintCmtSend);
    $('cmtInput').addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); sendComment(); } });
    $('momentList').addEventListener('touchstart', function (e) {
      if (!e.target.closest('.wx-moment-more') && !$('cmtBar').hidden) closeCommentBar();
    }, { passive: true });
    $('momentsBack').addEventListener('click', closeCommentBar);

    function deleteMoment(id) {
      api('/moments/' + encodeURIComponent(id), { method: 'DELETE' })
        .then(function () {
          S.moments = S.moments.filter(function (x) { return x.id !== id; });
          renderMoments();
          toast('已删除');
        })
        .catch(function (err) { toast(err.message); });
    }

    function applyMoment(m) {
      if (!m) return;
      var i = S.moments.findIndex(function (x) { return x.id === m.id; });
      if (i >= 0) { S.moments[i] = m; renderMoments(); }
    }

    $('momentsCamera').addEventListener('click', function () {
      $('pubMask').hidden = false;
    });

    /* 发表面板：「拍摄 / 照片或视频」「从手机相册选择」/「取消」——和微信一样，点哪行都能用 */
    function closePub() { $('pubMask').hidden = true; }
    $('pubCancel').addEventListener('click', closePub);
    $('pubMask').addEventListener('click', function (e) { if (e.target === $('pubMask')) closePub(); });
    // 「拍摄 / 从手机相册选择」都是 <label for=...>，点一下原生就唤起相机 / 相册；
    // 这里只负责把面板收起来（不拦默认行为）
    ['pubShoot', 'pubGallery'].forEach(function (id) {
      var el = $(id);
      if (!el) return;
      el.addEventListener('click', function (e) {
        /* App 里「从手机相册选择」直接进相册（原生选择器），网页版走原来的 input */
        if (id === 'pubGallery' && nativePicker()) {
          e.preventDefault();
          closePub();
          pickImages('momentPics', 9, function (files) { postMomentFiles(files); });
          return;
        }
        setTimeout(closePub, 60);
      });
    });

    /* 手机端换封面：选图 → 上传 → PATCH 到自己的资料 */
    $('coverFile').addEventListener('change', function (e) {
      var file = e.target.files && e.target.files[0];
      e.target.value = '';
      saveCoverFile(file);
    });
    function saveCoverFile(file) {
      if (!file) return;
      if (file.size > 12 * 1024 * 1024) { toast('图片不能超过 12MB'); return; }
      var reader = new FileReader();
      reader.onload = function () {
        var dataUrl = String(reader.result);
        // 先量一下尺寸：长图（明显比封面高）就让用户挑显示哪一段
        var probe = new Image();
        probe.onload = function () {
          uploadCover(dataUrl, file.name, probe.naturalHeight / Math.max(1, probe.naturalWidth) >= 1.2);
        };
        probe.onerror = function () { uploadCover(dataUrl, file.name, false); };
        probe.src = dataUrl;
      };
      reader.readAsDataURL(file);
    }

    /* 手机端换聊天背景：选图 → 上传 → 存到自己资料（和电脑版同一个字段） */
    $('chatBgFile').addEventListener('change', function (e) {
      var file = e.target.files && e.target.files[0];
      e.target.value = '';
      saveChatBgFile(file);
    });

    function uploadCover(dataUrl, filename, isLong) {
      toast('正在上传封面…');
      api('/upload', { method: 'POST', body: JSON.stringify({ dataUrl: dataUrl, filename: filename }) })
        .then(function (d) { return api('/me', { method: 'PATCH', body: JSON.stringify({ momentCover: d.url }) }); })
        .then(function (d) {
          if (d && d.user) S.me = d.user;
          applyCover();
          if (!isLong) { toast('封面换好了'); return; }
          setTimeout(function () {
            sheet([
              { label: '长图：显示上半部分', run: function () { setCoverPos(0); } },
              { label: '长图：显示中间', run: function () { setCoverPos(50); } },
              { label: '长图：显示下半部分', run: function () { setCoverPos(100); } }
            ]);
          }, 320);
        })
        .catch(function (err) { toast(err.message || '换封面失败'); });
    }

    function setCoverPos(pos) {
      api('/me', { method: 'PATCH', body: JSON.stringify({ momentCoverPos: pos }) })
        .then(function (d) {
          if (d && d.user) S.me = d.user;
          applyCover();
          toast(pos === 0 ? '已显示上半部分' : (pos === 100 ? '已显示下半部分' : '已居中显示'));
        })
        .catch(function (err) { toast(err.message || '保存失败'); });
    }

    /* 拍摄（相机拍一张）→ 上传 → 发表 */
    $('momentCam').addEventListener('change', function (e) {
      var files = Array.prototype.slice.call(e.target.files || []).slice(0, 1);
      e.target.value = '';
      if (!files.length) return;
      postMomentFiles(files);
    });

    /* 手机端发朋友圈：图片先上传，再一起提交 */
    $('momentPics').addEventListener('change', function (e) {
      var files = Array.prototype.slice.call(e.target.files || []);
      e.target.value = '';
      if (!files.length) return;
      postMomentFiles(files);
    });

    function postMomentFiles(files) {
      /* 规格：最多 9 张，超过就不给发（原来是把多的静默丢掉，容易让人以为发上去了） */
      if (files.length > 9) {
        toast('最多只能选 9 张图，你选了 ' + files.length + ' 张');
        return;
      }
      var pick = files;
      toast('正在上传 ' + pick.length + ' 张…');
      Promise.all(pick.map(function (f) {
        return new Promise(function (resolve, reject) {
          var reader = new FileReader();
          reader.onload = function () {
            api('/upload', { method: 'POST', body: JSON.stringify({ dataUrl: String(reader.result), filename: f.name }) })
              .then(function (d) { resolve(d.url); }).catch(reject);
          };
          reader.onerror = reject;
          reader.readAsDataURL(f);
        });
      })).then(function (urls) {
        return api('/moments', { method: 'POST', body: JSON.stringify({ content: '', images: urls }) });
      }).then(function () {
        toast('已发表，朋友们能看到了');
        return loadMoments();
      }).catch(function (err) { toast(err.message || '发表失败'); });
    }

    function postMomentText() {
      askInput('发表动态', '', 200, function (text) {
        if (!text) return;
        api('/moments', { method: 'POST', body: JSON.stringify({ content: text }) })
          .then(function () { toast('已发表'); return loadMoments(); })
          .catch(function (err) { toast(err.message || '发表失败'); });
      });
    }
    /* 手机端加好友：支持按微信号 / 用户名搜，也能把自己的号发给别人 */
    $('btnAddFriend').addEventListener('click', function () {
      sheet([
        { label: '搜索微信号 / 用户名加好友', run: addFriendByInput },
        { label: '我的微信号：' + ((S.me && S.me.username) || ''), run: function () { toast('把这串号发给对方，他就能加你'); } }
      ]);
    });
    function addFriendByInput() {
      askInput('对方的微信号 / 用户名', '', 24, function (v) {
        if (!v) return;
        toast('正在发送好友申请…');
        api('/friends/request', { method: 'POST', body: JSON.stringify({ username: v }) })
          .then(function (d) {
            if (d && d.accepted) { toast('你们已经是好友了'); loadContacts(); return; }
            toast('好友申请已发出，等对方通过');
            loadContacts();
          })
          .catch(function (e) { toast(e.message || '加好友失败'); });
      });
    }
    /* 点「我」页头像 → 打开「个人信息」（换头像就在资料页第一行，点一下也是直接进相册） */
    $('meAvatar').addEventListener('click', openProfile);
    /* 点名字/微信号 → 打开「个人信息」页（改名字、性别、手机号等） */
    (function () {
      var info = document.querySelector('#profileTop .me-info');
      if (info) info.addEventListener('click', openProfile);
    })();
    $('pfBack').addEventListener('click', closeProfile);
    $('pfNameRow').addEventListener('click', function () {
      askInput('修改名字', S.me.nickname || '', 24, function (v) {
        if (!v) return;
        saveMe({ nickname: v }, '名字已改好');
      });
    });
    $('pfGenderRow').addEventListener('click', function () {
      sheet([
        { label: '男', run: function () { saveMe({ gender: 'male' }, '性别已设为男'); } },
        { label: '女', run: function () { saveMe({ gender: 'female' }, '性别已设为女'); } }
      ]);
    });
    $('pfRegionRow').addEventListener('click', function () {
      askInput('修改地区', S.me.region || '', 40, function (v) { saveMe({ region: v }, '地区已保存'); });
    });
    $('pfBioRow').addEventListener('click', function () {
      askInput('修改个性签名', S.me.bio || '', 60, function (v) { saveMe({ bio: v }, '签名已保存'); });
    });
    $('pfAvatarRow').addEventListener('click', function () {
      pickImages('pfFile', 1, function (files) { saveAvatarFile(files[0]); });
    });
    /* 手机号：只能后台改，这里点一下说明一下 */
    $('pfPhoneRow').addEventListener('click', function () {
      openPhonePage();
    });
    /* 我的二维码：把我自己的微信号亮出来 */
    $('pfQrRow').addEventListener('click', function () {
      sheet([{ label: '微信号：' + (S.me.username || ''), run: function () { toast('把这串号发给对方，他就能加你'); } }]);
    });
    /* 拍一拍：改的是本机记录的文字 */
    $('pfPatRow').addEventListener('click', function () {
      askInput('拍一拍（别人拍你会显示这句）', localOf('wx-pat', '朋友拍了拍你'), 20, function (v) {
        if (!v) return;
        setLocal('wx-pat', v);
        renderProfile();
        toast('拍一拍已保存');
      });
    });
    /* 来电铃声：本机选择 */
    $('pfRingRow').addEventListener('click', function () {
      sheet(['本机默认', '清脆', '叮咚', '震动'].map(function (n) {
        return { label: n, run: function () { setLocal('wx-ring', n); renderProfile(); toast('来电铃声：' + n); } };
      }));
    });
    $('pfFile').addEventListener('change', function (e) {
      var file = e.target.files && e.target.files[0];
      e.target.value = '';
      saveAvatarFile(file);
    });
    function saveAvatarFile(file) {
      if (!file) return;
      if (file.size > 12 * 1024 * 1024) { toast('图片不能超过 12MB'); return; }
      var reader = new FileReader();
      reader.onload = function () {
        api('/upload', { method: 'POST', body: JSON.stringify({ dataUrl: String(reader.result), filename: file.name }) })
          .then(function (d) { return saveMe({ avatar: d.url }, '头像已换好'); })
          .catch(function (err) { toast(err.message); });
      };
      reader.readAsDataURL(file);
    }
    $('askCancel').addEventListener('click', closeAsk);
    $('askOk').addEventListener('click', function () {
      var cb = askHandler, v = $('askInput').value.trim();
      closeAsk();
      if (cb) cb(v);
    });
    $('askInput').addEventListener('keydown', function (e) { if (e.key === 'Enter') $('askOk').click(); });
    $('askMask').addEventListener('click', function (e) { if (e.target === $('askMask')) closeAsk(); });
  }

  /* ---------------------------------------------------------- 语音 / 视频通话（手机端）
     信令走和电脑版同一条 WebSocket（type:'call'），媒体走 WebRTC。
     注意：浏览器只允许「安全页面」用麦克风/摄像头，所以手机上要用 https 打开（或 localhost）。 */
  var CALL_STUN = [
    'stun:stun.l.google.com:19302',
    'stun:stun1.l.google.com:19302',
    'stun:stun.cloudflare.com:3478',
    'stun:stun.miwifi.com:3478'
  ];
  var call = null;            // { id, peerId, peerName, peerAvatar, role, media, pc, stream, timer, facing, ... }
  var callBranding = null;

  function callSupported() {
    return !!(window.RTCPeerConnection && navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
  }

  function mcall() {
    return {
      screen: $('callScreen'), remote: $('callRemote'), local: $('callLocal'), avatar: $('callAvatar'),
      name: $('callName'), status: $('callStatus'), timer: $('callTimer'), accept: $('callAccept'),
      hangup: $('callHangup'), mute: $('callMute'), cam: $('callCam'), flip: $('callFlip')
    };
  }

  function callSendMsg(o) {
    if (socket && socket.readyState === 1) { try { socket.send(JSON.stringify(o)); } catch (e) { /* 忽略 */ } }
  }

  /** 通话用的 ICE 服务器：后台「语音通话」里填了就用它，没填就用默认公共 STUN */
  function callIceServers() {
    var raw = String((callBranding && callBranding.iceServers) || '').trim();
    var list = [];
    if (raw) {
      try { var parsed = JSON.parse(raw); list = Array.isArray(parsed) ? parsed : [parsed]; }
      catch (e) { list = raw.split(/[\n,]+/); }
    }
    var servers = list.map(function (it) {
      if (typeof it === 'string') return { urls: it };
      return (it && it.urls) ? it : null;
    }).filter(Boolean).filter(function (s) {
      var u = s.urls;
      if (typeof u === 'string') return /^(stun|turn|turns):/i.test(u);
      if (Object.prototype.toString.call(u) === '[object Array]') {
        return u.some(function (x) { return /^(stun|turn|turns):/i.test(String(x)); });
      }
      return false;
    });
    if (!servers.length) servers = CALL_STUN.map(function (u) { return { urls: u }; });
    /* 兜底：自己服务器上的 TURN（TCP 那条才通），保证总有中转可用 */
    var h = location.hostname;
    if (h) {
      servers.push({
        /* 只留 TCP（和网页版一致）：两端同一种通道才能配对上 */
        urls: ['turn:' + h + ':3478?transport=tcp'],
        username: 'chris', credential: 'chris1234'
      });
    }
    return servers;
  }

  function loadCallBranding() {
    if (callBranding) return Promise.resolve(callBranding);
    return api('/branding').then(function (d) { callBranding = (d && d.branding) || {}; return callBranding; })
      .catch(function () { callBranding = {}; return callBranding; });
  }

  var netWaiters = {};
  function callAskNet(peerId) {   /* 问服务器：两端是不是同一个网络（拿不到就按不同网络＝走中继） */
    return new Promise(function (res) {
      netWaiters[peerId] = res;
      callSendMsg({ type: 'call', action: 'net', peerId: peerId });
      setTimeout(function () {
        if (netWaiters[peerId]) { var f = netWaiters[peerId]; delete netWaiters[peerId]; f(false); }
      }, 1200);
    });
  }
  function callNetAnswer(msg) {
    var pid = msg.peerId || '';
    if (netWaiters[pid]) { var f = netWaiters[pid]; delete netWaiters[pid]; f(!!msg.same); }
    return true;
  }

  function callMakePc() {
    /* 走不走中继由「两端是不是同一个网络」决定（问服务器拿的，见 callAskNet）：
       同一个网络 → 直连（快、不占带宽）；不同网络 → 强制中继（不然常只通一半）。
       服务器本身在局域网（本机部署）时也直连。 */
    var h = location.hostname || '';
    var lan = /^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(h);
    /* 连的是公网服务器就一律走中继：两端策略完全一致，不存在"一边中继一边直连"的半通情况。
       （局域网部署才直连） */
    var useRelay = !lan;
    var pc = new RTCPeerConnection({ iceServers: callIceServers(), iceTransportPolicy: useRelay ? 'relay' : 'all' });
    /* 手机网页版也报诊断（和 App 一样），连不上时后台能看到这半边的状态 */
    pc.onicecandidate = function (e) {
      if (e.candidate && call) {
        if (!call.candTypes) call.candTypes = [];
        call.candTypes.push(e.candidate.type + '/' + ((e.candidate.protocol) || '?'));
      }
    };
    pc.oniceconnectionstatechange = function () {
      if (!call) return;
      var c = call;
      if (pc.iceConnectionState === 'failed' || pc.iceConnectionState === 'disconnected') {
        try {
          fetch('/api/call-diag', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text: '手机网页' + (c.answerSent ? '(被叫)' : '(主叫)') + ' ' + (c.media || 'audio')
              + ' 结果=连接失败 ice=' + pc.iceConnectionState
              + ' gathering=' + pc.iceGatheringState
              + ' 候选=' + ((c.candTypes || []).join(', ') || '无') })
          });
        } catch (err) { }
      }
    };
    pc.addEventListener('track', function (ev) {
      var el = mcall();
      if (el.remote && ev.streams && ev.streams[0] && el.remote.srcObject !== ev.streams[0]) {
        el.remote.srcObject = ev.streams[0];
        var p = el.remote.play();
        if (p && p.catch) p.catch(function () { /* 自动播放被挡就先放着，用户点一下就出画面 */ });
      }
    });
    pc.addEventListener('icecandidate', function (ev) {
      if (ev.candidate && call) {
        callSendMsg({ type: 'call', action: 'ice', callId: call.id, candidate: ev.candidate.toJSON ? ev.candidate.toJSON() : ev.candidate });
      }
    });
    pc.addEventListener('connectionstatechange', function () {
      if (!call || call.pc !== pc) return;
      var st = pc.connectionState;
      if (st === 'connected') { if (call) call.started = true; callSetPhase('active'); callStartTimer(); }
      else if (st === 'failed') { toast('通话连接失败，可能是网络挡住了'); callHangup(true); }
      else if (st === 'disconnected') {
        setTimeout(function () {
          if (call && call.pc === pc && pc.connectionState === 'disconnected') callHangup(true);
        }, 3000);
      }
    });
    return pc;
  }

  function callGetMedia(video) {
    var wantVideo = !!video;
    var constraints = {
      audio: true,
      video: wantVideo ? { facingMode: (call && call.facing) || 'user', width: { ideal: 720 }, height: { ideal: 1280 } } : false
    };
    return navigator.mediaDevices.getUserMedia(constraints);
  }

  function callMediaFail(err) {
    var s = String((err && (err.name || err.message)) || '');
    if (/NotAllowedError|Permission/i.test(s)) toast('没给麦克风/摄像头权限：在浏览器地址栏里允许一次');
    else if (/NotFoundError|DevicesNotFound/i.test(s)) toast('这台设备没有麦克风或摄像头');
    else if (!window.isSecureContext) toast('通话要用 https 打开才行：浏览器只让安全页面用麦克风');
    else toast('打不开麦克风/摄像头：' + s);
  }

  /** 等 ICE 收集完（最多 2.5 秒）：SDP 里自带候选，弱网比逐条发稳 */
  function callWaitIce(pc) {
    return new Promise(function (resolve) {
      if (pc.iceGatheringState === 'complete') return resolve();
      var done = false;
      var finish = function () {
        if (done) return;
        done = true;
        pc.removeEventListener('icegatheringstatechange', onChange);
        resolve();
      };
      var onChange = function () { if (pc.iceGatheringState === 'complete') finish(); };
      pc.addEventListener('icegatheringstatechange', onChange);
      setTimeout(finish, 2500);
    });
  }

  function callAddRemoteCandidate(cand) {
    if (!call || !cand) return;
    if (call.pc && call.pc.remoteDescription) {
      call.pc.addIceCandidate(new RTCIceCandidate(cand)).catch(function () { /* 单条失败不影响其它 */ });
    } else {
      call.pending.push(cand);
    }
  }

  function callFlushCandidates() {
    if (!call || !call.pc || !call.pc.remoteDescription) return;
    var list = call.pending || [];
    call.pending = [];
    list.forEach(function (c) { call.pc.addIceCandidate(new RTCIceCandidate(c)).catch(function () { }); });
  }

  function callSetPhase(phase) {
    var el = mcall();
    if (!el.screen) return;
    var media = (call && call.media) || 'audio';
    var video = media === 'video';
    var live = phase === 'calling' || phase === 'connecting' || phase === 'active';
    el.screen.hidden = false;
    el.screen.classList.toggle('is-video', video && phase === 'active');
    el.name.textContent = (call && call.peerName) || '—';
    el.avatar.innerHTML = (call && call.peerAvatar) ? '<img src="' + esc(call.peerAvatar) + '" alt="">' : '<span>' + esc(((call && call.peerName) || '?').slice(0, 1)) + '</span>';
    el.accept.hidden = phase !== 'incoming';
    el.hangup.hidden = phase === 'incoming' ? false : false;
    el.mute.hidden = !live;
    el.cam.hidden = !(video && live);
    el.flip.hidden = !(video && live);
    el.local.hidden = !(video && (phase === 'connecting' || phase === 'active'));
    el.cam.classList.toggle('is-off', !!(call && call.camOff));
    if (phase === 'incoming') el.status.textContent = video ? '邀请你视频通话…' : '邀请你语音通话…';
    else if (phase === 'calling') el.status.textContent = video ? '正在视频呼叫…' : '正在语音呼叫…';
    else if (phase === 'connecting') el.status.textContent = '已接听，正在连接…';
    else if (phase === 'active') el.status.textContent = video ? '视频通话中' : '语音通话中';
    else if (phase === 'ended') { el.status.textContent = '通话已结束'; el.mute.hidden = true; el.cam.hidden = true; el.flip.hidden = true; el.local.hidden = true; el.accept.hidden = true; }
  }

  function callStartTimer() {
    if (!call || call.timer) return;
    var el = mcall();
    el.timer.hidden = false;
    var t0 = Date.now();
    var tick = function () {
      var s = Math.floor((Date.now() - t0) / 1000);
      el.timer.textContent = ('0' + Math.floor(s / 60)).slice(-2) + ':' + ('0' + (s % 60)).slice(-2);
    };
    tick();
    call.timer = setInterval(tick, 500);
  }

  function callClose(delay) {
    var cur = call;
    if (cur && cur.timer) clearInterval(cur.timer);
    if (cur && cur.pc) { try { cur.pc.close(); } catch (e) { /* 忽略 */ } }
    if (cur && cur.stream) cur.stream.getTracks().forEach(function (t) { t.stop(); });
    call = null;
    setTimeout(function () {
      var el = mcall();
      if (!el.screen) return;
      el.screen.hidden = true;
      el.screen.classList.remove('is-video');
      if (el.remote) el.remote.srcObject = null;
      if (el.local) el.local.srcObject = null;
      el.timer.hidden = true;
      el.timer.textContent = '00:00';
    }, delay || 900);
  }

  /** 当前会话的通话对象（只支持一对一会话） */
  function callPeer() {
    var chat = (S.chats || []).filter(function (c) { return c.id === S.activeChat; })[0];
    if (!chat) return null;
    var otherId = (chat.memberIds || []).filter(function (id) { return id !== S.me.id; })[0];
    if (!otherId) return null;
    var f = (S.friends || []).filter(function (x) { return x.id === otherId; })[0] || {};
    return { id: otherId, name: chat.title || f.nickname || '', avatar: chat.avatar || f.avatar || '', bot: !!f.bot };
  }

  /* ================= AI 语音通话 =================
     不用 WebRTC：手机把你说的话转成文字发给 AI，AI 的文字回复用系统语音念出来。
     除了「说话」，直接打字也行（它照样念给你听）。 */
  var aiCall = { rec: null, speaking: false, thinking: false, running: false };
  function startAiCall(peer, media) {
    if (call) return toast('已经在通话里了');
    call = {
      id: 'aicall' + Date.now(), peerId: peer.id, peerName: peer.name, peerAvatar: peer.avatar, role: 'caller',
      media: 'audio', pc: null, stream: null, timer: null, muted: false, camOff: false, facing: 'user',
      pending: [], started: true, ai: true
    };
    aiCall.running = true;
    callSetPhase('active');
    callStartTimer();
    var el = mcall();
    if (el.status) el.status.textContent = '正在接通…';
    setTimeout(function () {
      if (!call || !call.ai) return;
      aiCallSpeak('你好，我是' + (peer.name || 'AI'), function () { aiCallListen(); });
    }, 400);
  }
  /* 选嗓子：贾维斯 = 男声、稳一点、有质感；AI 助手 = 默认女声。
     系统里能挑到中文男声就用男声；挑不到（比如 iPhone 只装了婷婷）就把音高压低，
     听起来一样是偏低沉的男声。想更自然可以到「设置 → 辅助功能 → 朗读内容 → 语音 → 中文」
     下载更多声音，下载后这里会自动挑男声用。 */
  function aiVoicePick(name) {
    var vs = [];
    try { vs = (window.speechSynthesis && speechSynthesis.getVoices()) || []; } catch (e) { vs = []; }
    var zh = [];
    for (var i = 0; i < vs.length; i++) {
      var v = vs[i];
      if (/zh|Chinese|Ting|Mei|Sin/i.test(String(v.lang) + ' ' + String(v.name))) zh.push(v);
    }
    if (/贾维斯/.test(String(name || ''))) {
      var maleRe = /(Yunxi|Yunyang|Yunjian|Yunye|Yunhao|Yunfeng|Kangkang|Yushu|Yu-Shu|Alex|Daniel|云希|云扬|云健|云野|云皓|语舒|男)/i;
      for (var k = 0; k < zh.length; k++) {
        if (maleRe.test(zh[k].name)) return { voice: zh[k], pitch: 0.95, rate: 0.98 };
      }
      return { voice: zh[0] || null, pitch: 0.72, rate: 0.97 };   // 压低音高 → 男中音
    }
    return { voice: zh[0] || null, pitch: 1, rate: 1.05 };
  }
  function aiCallStop() {
    aiCall.running = false; aiCall.speaking = false; aiCall.thinking = false;
    if (aiCall.rec) { try { aiCall.rec.abort(); } catch (e) { } aiCall.rec = null; }
    try { if (window.speechSynthesis) speechSynthesis.cancel(); } catch (e) { }
  }
  function aiCallSpeak(text, done) {
    if (!call || !call.ai) return;
    aiCall.thinking = false; aiCall.speaking = true;
    var el = mcall();
    var clean = String(text || '').replace(/[#*`>]/g, '').slice(0, 300);
    if (el.status) el.status.textContent = '「' + clean.slice(0, 22) + (clean.length > 22 ? '…' : '') + '」';
    var finished = false;
    var finish = function () {
      if (finished) return;
      finished = true; aiCall.speaking = false;
      if (!aiCall.running) return;
      if (done) done(); else aiCallListen();
    };
    try {
      if (!window.speechSynthesis) { finish(); return; }
      speechSynthesis.cancel();
      var u = new SpeechSynthesisUtterance(clean);
      u.lang = 'zh-CN';
      /* 嗓子：贾维斯走男声（挑得到男声就用，挑不到就把音高压低成男声）；AI 助手用默认 */
      var pick = aiVoicePick(call && call.peerName);
      if (pick.voice) u.voice = pick.voice;
      u.rate = pick.rate; u.pitch = pick.pitch;
      u.onend = finish; u.onerror = finish;
      speechSynthesis.speak(u);
      setTimeout(finish, Math.max(4000, clean.length * 340));   // 兜底：有的机型 onend 不触发
    } catch (e) { finish(); }
  }
  function aiCallListen() {
    if (!call || !call.ai || !aiCall.running) return;
    var el = mcall();
    var Rec = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!Rec) {
      if (el.status) el.status.textContent = '这台设备不支持语音识别，你打字我念给你听';
      return;
    }
    var rec = new Rec();
    aiCall.rec = rec;
    rec.lang = 'zh-CN'; rec.continuous = false; rec.interimResults = true; rec.maxAlternatives = 1;
    rec.onstart = function () { if (el.status && !aiCall.thinking) el.status.textContent = '我在听…'; };
    rec.onresult = function (e) {
      var interim = '', final = '';
      for (var i = e.resultIndex; i < e.results.length; i++) {
        var t = e.results[i][0].transcript;
        if (e.results[i].isFinal) final += t; else interim += t;
      }
      if (interim && el.status) el.status.textContent = '「' + interim.trim().slice(0, 20) + '」';
      if (final.trim()) aiCallAsk(final.trim());
    };
    rec.onerror = function (ev) {
      var err = (ev && ev.error) || '';
      if (err === 'not-allowed' || err === 'service-not-allowed') {
        if (el.status) el.status.textContent = '没有麦克风权限，去「设置 → 隐私 → 麦克风」里允许一下';
        aiCall.running = false;
      }
    };
    rec.onend = function () {
      if (!call || !call.ai || !aiCall.running || aiCall.speaking || aiCall.thinking) return;
      setTimeout(function () { try { rec.start(); } catch (e) { } }, 350);   // 一直听着
    };
    try { rec.start(); } catch (e) { }
  }
  function aiCallAsk(text) {
    if (!text || !call || !call.ai) return;
    aiCall.thinking = true;
    var el = mcall();
    if (el.status) el.status.textContent = '你在说：「' + text.slice(0, 20) + '」';
    try { if (aiCall.rec) aiCall.rec.stop(); } catch (e) { }
    if (S.activeChat === callChatId()) sendText(text);       // 正常发消息：聊天里也留记录
  }
  function callChatId() {
    var chat = (S.chats || []).filter(function (c) { return c.id === S.activeChat; })[0];
    return chat ? chat.id : null;
  }

  function startCall(media) {
    if (call) return toast('已经在通话里了');
    var peer = callPeer();
    if (!peer || !peer.id) return toast('先打开一个一对一的聊天，再打电话');
    /* 跟 AI（AI 助手 / 贾维斯AI）打电话：不走 WebRTC，直接「说话 → 它听懂 → 它用语音回你」 */
    if (peer.bot) { startAiCall(peer, media); return; }
    if (!callSupported()) return toast('这个浏览器不支持通话');
    if (!window.isSecureContext) return toast('通话要用 https 打开才行（浏览器只让安全页面用麦克风）');
    media = media === 'video' ? 'video' : 'audio';
    loadCallBranding().then(function () {
      var callId = 'call' + Date.now() + Math.random().toString(16).slice(2, 6);
      call = {
        id: callId, peerId: peer.id, peerName: peer.name, peerAvatar: peer.avatar, role: 'caller',
        media: media, pc: null, stream: null, timer: null, muted: false, camOff: false, facing: 'user',
        pending: [], started: false
      };
      callSetPhase('calling');
      /* 先问服务器：两端是不是同一个网络 → 同一个直连、不同强制中继 */
      callAskNet(peer.id).then(function (same) {
        if (!call || call.id !== callId) return null;
        call.sameNet = same;
        call.pc = callMakePc();
        return callGetMedia(media === 'video').then(function (stream) {
        call.stream = stream;
        stream.getTracks().forEach(function (t) { call.pc.addTrack(t, stream); });
        var el = mcall();
        if (el.local) { el.local.srcObject = stream; var p = el.local.play(); if (p && p.catch) p.catch(function () { }); }
        return call.pc.createOffer({ offerToReceiveAudio: true, offerToReceiveVideo: media === 'video' })
          .then(function (offer) { return call.pc.setLocalDescription(offer); })
          .then(function () { return callWaitIce(call.pc); })
          .then(function () {
            var local = call.pc.localDescription;
            callSendMsg({ type: 'call', action: 'invite', callId: callId, toUserId: peer.id, media: media, sdp: { type: local.type, sdp: local.sdp } });
          });
        });
      }).catch(function (err) {
        var was = call && call.media;
        call = null;
        callClose(0);
        callMediaFail(err);
        if (was) toast('这次没能拨出去');
      });
    });
  }

  function acceptCall() {
    if (!call || call.role !== 'callee') return;
    if (!call.pc) call.pc = callMakePc();     // 网络的回答还没到就直接点接听了
    callSetPhase('connecting');
    callGetMedia(call.media === 'video').then(function (stream) {
      call.stream = stream;
      stream.getTracks().forEach(function (t) { call.pc.addTrack(t, stream); });
      var el = mcall();
      if (el.local) { el.local.srcObject = stream; var p = el.local.play(); if (p && p.catch) p.catch(function () { }); }
      return call.pc.setRemoteDescription(new RTCSessionDescription(call.offer))
        .then(function () { callFlushCandidates(); return call.pc.createAnswer(); })
        .then(function (answer) { return call.pc.setLocalDescription(answer); })
        .then(function () { return callWaitIce(call.pc); })
        .then(function () {
          var local = call.pc.localDescription;
          callSendMsg({ type: 'call', action: 'accept', callId: call.id, sdp: { type: local.type, sdp: local.sdp } });
        });
    }).catch(function (err) {
      var id = call && call.id;
      if (id) callSendMsg({ type: 'call', action: 'reject', callId: id });
      call = null;
      callClose(0);
      callMediaFail(err);
    });
  }

  function callHangup(silent) {
    if (!call) { var el0 = mcall(); if (el0.screen) el0.screen.hidden = true; return; }
    if (call.ai) { aiCallStop(); callSetPhase('ended'); callClose(700); return; }   // AI 通话：不用发信令
    var id = call.id, role = call.role, started = call.started;
    if (!silent) callSendMsg({ type: 'call', action: started ? 'hangup' : (role === 'caller' ? 'cancel' : 'reject'), callId: id });
    callSetPhase('ended');
    callClose(900);
  }

  function toggleCallMute() {
    if (call && call.ai) {                       // AI 通话：静音 = 先不听你说
      call.muted = !call.muted;
      var elA = mcall();
      elA.mute.classList.toggle('is-off', call.muted);
      elA.mute.querySelector('span').textContent = call.muted ? '已静音' : '静音';
      if (call.muted) {
        if (aiCall.rec) { try { aiCall.rec.abort(); } catch (e) { } }
        try { if (window.speechSynthesis) speechSynthesis.cancel(); } catch (e) { }
        if (elA.status) elA.status.textContent = '已静音，点一下继续';
      } else { aiCallListen(); }
      return;
    }
    if (!call || !call.stream) return;
    call.muted = !call.muted;
    call.stream.getAudioTracks().forEach(function (t) { t.enabled = !call.muted; });
    var el = mcall();
    el.mute.classList.toggle('is-off', call.muted);
    el.mute.querySelector('span').textContent = call.muted ? '已静音' : '静音';
  }

  function toggleCallCam() {
    if (!call || !call.stream) return;
    var tracks = call.stream.getVideoTracks();
    call.camOff = !call.camOff;
    tracks.forEach(function (t) { t.enabled = !call.camOff; });
    var el = mcall();
    el.cam.classList.toggle('is-off', call.camOff);
    el.cam.querySelector('span').textContent = call.camOff ? '开摄像头' : '摄像头';
  }

  function flipCallCamera() {
    if (!call || !call.stream || call.media !== 'video') return;
    call.facing = call.facing === 'user' ? 'environment' : 'user';
    navigator.mediaDevices.getUserMedia({ video: { facingMode: call.facing }, audio: false }).then(function (s) {
      var fresh = s.getVideoTracks()[0];
      var old = call.stream.getVideoTracks()[0];
      if (!fresh || !call) { s.getTracks().forEach(function (t) { t.stop(); }); return; }
      var sender = call.pc.getSenders().filter(function (x) { return x.track && x.track.kind === 'video'; })[0];
      if (sender) sender.replaceTrack(fresh);
      if (old) { call.stream.removeTrack(old); old.stop(); }
      call.stream.addTrack(fresh);
      var el = mcall();
      if (el.local) el.local.srcObject = call.stream;
    }).catch(function () { /* 有些设备只有一个摄像头，翻转失败就算了 */ });
  }

  function handleCallEvent(msg) {
    if (msg.action === 'net') { callNetAnswer(msg); return; }   // 服务器回答「两端是不是同一个网络」
    if (msg.action === 'incoming') {
      if (call) { callSendMsg({ type: 'call', action: 'reject', callId: msg.callId }); return; }
      call = {
        id: msg.callId, peerId: msg.peerId, peerName: msg.peerName || '好友', peerAvatar: msg.peerAvatar || '',
        role: 'callee', media: msg.media === 'video' ? 'video' : 'audio', offer: msg.sdp || null,
        pc: null, stream: null, timer: null, muted: false, camOff: false, facing: 'user', pending: [], started: false
      };
      callSetPhase('incoming');
      /* 先问服务器两端是不是同一个网络（拿回答之前先不建连接，回答一到就按直连/中继建） */
      callAskNet(msg.peerId).then(function (same) {
        if (call && call.id === msg.callId && !call.pc) { call.sameNet = same; call.pc = callMakePc(); }
      });
      if (navigator.vibrate) { try { navigator.vibrate([300, 200, 300, 200, 300]); } catch (e) { } }
      return;
    }
    if (msg.type === 'call-error') { toast(msg.error || '对方接不了这通电话'); return; }
    if (!call) return;
    if (msg.callId && msg.callId !== call.id) return;   // 过期的信令忽略
    if (msg.action === 'ringing') { callSetPhase('calling'); return; }
    if (msg.action === 'accepted') { callSetPhase('connecting'); return; }
    if (msg.action === 'sdp') {
      var desc = msg.sdp;
      if (!desc) return;
      if (call.pc.signalingState === 'closed') return;
      call.pc.setRemoteDescription(new RTCSessionDescription(desc)).then(function () {
        callFlushCandidates();
        if (call.pc.connectionState === 'connected') { call.started = true; callSetPhase('active'); callStartTimer(); }
      }).catch(function () { });
      return;
    }
    if (msg.action === 'ice') { callAddRemoteCandidate(msg.candidate); return; }
    if (msg.action === 'media') { call.media = msg.media === 'video' ? 'video' : 'audio'; callSetPhase(call.started ? 'active' : 'connecting'); return; }
    if (msg.action === 'end') {
      call.started = call.started && msg.reason === 'hangup';
      callSetPhase('ended');
      callClose(900);
      return;
    }
  }

  function initMobileCall() {
    var el = mcall();
    if (!el.screen) return;
    if (el.accept) el.accept.addEventListener('click', acceptCall);
    if (el.hangup) el.hangup.addEventListener('click', function () { callHangup(false); });
    if (el.mute) el.mute.addEventListener('click', toggleCallMute);
    if (el.cam) el.cam.addEventListener('click', toggleCallCam);
    if (el.flip) el.flip.addEventListener('click', flipCallCamera);
  }

  bind();
  initMobileCall();
  bindPullRefresh();
  bindMeStretch();
  bindTopBounce();
  bindPhonePage();
  bindStatusPage();
  bindTransferPage();
  bindNoteSheet();
  bindPaySheet();
  bindSecurityCenter();
  bindTransferDetail();
  bindMsgLongPress();
  bindLocationPicker();
  bindVersionCheck();
  bindMomentsBadgeWatch();
  loadBrandFont();
  boot().then(function () { pendingJoin(); pendingAdd(); });

  /* ---------------- 适配各种机型 ---------------- */
  (function adaptive() {
    // 1) 可视高度：键盘弹出 / 地址栏收起时，聊天页跟着变，输入框不会被顶掉
    var vv = window.visualViewport;
    function syncHeight() {
      var winH = window.innerHeight;
      var vh = vv ? vv.height : winH;
      // 只有键盘真的弹出（可视高度少了 120px 以上）才算键盘高度；
      // 平时 --kb = 0，输入栏就固定钉在屏幕底部，不会自己往上跑
      var kb = winH - vh;
      document.documentElement.style.setProperty('--kb', (kb > 120 ? Math.round(kb) : 0) + 'px');
    }
    syncHeight();
    window.addEventListener('resize', syncHeight);
    window.addEventListener('orientationchange', function () { setTimeout(syncHeight, 250); });
    if (vv) { vv.addEventListener('resize', syncHeight); vv.addEventListener('scroll', syncHeight); }

    // 2) 横竖屏 / 大屏切换时，重新算一次标题和未读（布局由 CSS clamp 自适应）
    window.addEventListener('orientationchange', function () {
      setTimeout(function () { renderChats(); renderContacts(); }, 300);
    });
  })();
})();
