(function () {
  'use strict';

  /* 桌面软件：禁止一切 "新开浏览器窗口/网页" 的行为。
     图片一律在软件内部全屏查看（微信那样）。 */
  (function () {
    try {
      window.open = function (url) {
        var u = '';
        try { u = String(url || ''); } catch (e) { u = ''; }
        if (u && (/\.(png|jpe?g|gif|webp|bmp|avif|svg)(\?|#|$)/i.test(u) || u.indexOf('/uploads/') !== -1)) {
          try { openPhotoView([u], 0); } catch (e) { }
        }
        return null;
      };
    } catch (e) { }
  })();

  var API = '/api';
  var state = {
    me: null,
    chats: [],
    friends: [],
    incoming: [],
    outgoing: [],
    online: {},
    userCache: {},
    messages: {},
    activeChatId: null,
    panel: 'chats',
    authMode: 'login',
    typing: {},
    wsReady: false,
    moments: [],
    momentUser: null,
    voicePlayed: null,
    authAccount: null,
    statuses: {},
    loadedVersion: null,
    pairing: false, pairCode: null, pairTimer: null, pendingPairCode: null, captchaId: null,
    momentUserInfo: null,
    momentUnread: 0,
    composeImages: [],
    coverDraft: '',
    listFilter: 'all',
    branding: null,
    appName: 'CHRIS Chat'
  };

  var socket = null;
  var reconnectDelay = 800;
  var pending = {};
  var toastTimer = null;

  /* 画中画窗口（朋友圈浮窗）：元素搬进搬出时要能在两个 document 里找到 */
  var momentsPip = null;
  var momentsHome = null;

  var $ = function (id) {
    var el = document.getElementById(id);
    if (el) return el;
    if (momentsPip && !momentsPip.closed) {
      try { return momentsPip.document.getElementById(id); } catch (e) { return null; }
    }
    return null;
  };

  /** 当前该往哪个 document 里弹东西：朋友圈在画中画里就弹到画中画 */
  function activeDoc() {
    if (momentsPip && !momentsPip.closed) {
      try {
        var pane = momentsPip.document.getElementById('momentsPane');
        if (pane && !pane.hidden) return momentsPip.document;
      } catch (e) { /* 忽略 */ }
    }
    return document;
  }

  function esc(v) {
    return String(v == null ? '' : v)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function initials(name) {
    var s = String(name || '?').trim();
    return s ? s.slice(0, 1).toUpperCase() : '?';
  }

  function api(path, options) {
    var opts = options || {};
    opts.headers = Object.assign({ 'Content-Type': 'application/json' }, opts.headers || {});
    return fetch(API + path, opts).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (body) {
        if (!res.ok || body.ok === false) {
          var detail = body.details && body.details.length ? '：' + body.details.join('；') : '';
          var err = new Error((body.error || ('请求失败 ' + res.status)) + detail);
          err.status = res.status;
          // 改过密码 / 在别处点了「退出其他设备」后，旧会话会失效 → 回登录页
          if (res.status === 401 && state.me &&
            String(path).indexOf('/login') !== 0 && String(path).indexOf('/register') !== 0) {
            forceLogout('登录状态已失效，请重新登录');
          }
          throw err;
        }
        return body.data;
      });
    });
  }

  var forcingLogout = false;
  function forceLogout(message) {
    if (forcingLogout) return;
    forcingLogout = true;
    toast(message || '请重新登录', 'error');
    setTimeout(function () { location.reload(); }, 1300);
  }

  function toast(message, tone) {
    var node = $('toast');
    node.textContent = message;
    node.setAttribute('data-tone', tone || '');
    node.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { node.hidden = true; }, 2600);
  }

  function formatTime(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '';
    var now = new Date();
    var hm = String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
    if (d.toDateString() === now.toDateString()) return hm;
    var sameYear = d.getFullYear() === now.getFullYear();
    return (sameYear ? (d.getMonth() + 1) + '月' + d.getDate() + '日' : d.getFullYear() + '/' + (d.getMonth() + 1) + '/' + d.getDate());
  }

  function dayLabel(iso) {
    var d = new Date(iso);
    var now = new Date();
    if (d.toDateString() === now.toDateString()) return '今天';
    var y = new Date(now.getTime() - 86400000);
    if (d.toDateString() === y.toDateString()) return '昨天';
    return (d.getMonth() + 1) + '月' + d.getDate() + '日';
  }

  function avatarHtml(url, name, cls, userId) {
    var tag = cls || 'div';
    var link = userId ? ' js-avatar-link" data-goto-moments="' + esc(userId) + '" title="看 TA 的朋友圈' : '';
    var open = '<' + tag + ' class="row-avatar' + link + '">';
    var close = '</' + tag + '>';
    if (url) return open + '<img src="' + esc(url) + '" alt="">' + close;
    return open + esc(initials(name)) + close;
  }

  /** 名片名字旁边的性别图标（以后台 / 注册时填的为准） */
  function genderIconHtml(gender) {
    if (gender === 'male') {
      return '<span class="gender-ico is-male" title="男"><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M15.6 2.5h5.9v5.9h-2.2V6.4l-4 4a5.9 5.9 0 1 1-1.6-1.6l4-4h-2.1V2.5zM9.9 9.5a3.7 3.7 0 1 0 0 7.4 3.7 3.7 0 0 0 0-7.4z"/></svg></span>';
    }
    if (gender === 'female') {
      return '<span class="gender-ico is-female" title="女"><svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 2.4a6 6 0 0 1 2.4 11.5v1.7h2.3v2.2h-2.3v2.3h-2.2v-2.3H9.9v-2.2h2.3v-1.8A6 6 0 0 1 12 2.4zm0 2.2a3.8 3.8 0 1 0 0 7.6 3.8 3.8 0 0 0 0-7.6z"/></svg></span>';
    }
    return '';
  }

  /** 离线、隐身的用户头像显示成灰色（和微信一致）；忙碌/离开不算离线 */
  function isOfflineUser(userId) {
    if (!userId) return false;
    if (state.me && userId === state.me.id) return false;
    var st = state.statuses ? state.statuses[userId] : '';
    if (st === 'offline' || st === 'invisible') return true;
    return !state.online[userId];
  }

  /** 按在线状态给页面上所有头像统一加/去灰色 */
  function markOfflineAvatars(root) {
    var scope = root || document;
    var nodes = scope.querySelectorAll('.row-avatar, .msg-avatar, .moment-avatar, .wxcard-face, .chat-head-avatar');
    Array.prototype.forEach.call(nodes, function (el) {
      var uid = el.getAttribute('data-goto-moments') || el.getAttribute('data-uid') || '';
      if (!uid) { el.classList.remove('is-offline'); return; }
      el.classList.toggle('is-offline', isOfflineUser(uid));
    });
  }

  /* --------------------------------------------------------------- 登录 */

  /* ------------------------------- 记住密码 / 自动登录 / 忘记密码 / 设备登录 */

  function rememberKey(username) { return 'chris-pw-' + username; }

  /** 只是本地混淆存一下，不是加密：QQ 也是把密码存在本机 */
  function savePassword(username, password) {
    if (!username) return;
    try { localStorage.setItem(rememberKey(username), btoa(unescape(encodeURIComponent(password)))); } catch (e) { /* 忽略 */ }
  }

  function loadPassword(username) {
    if (!username) return '';
    try {
      var v = localStorage.getItem(rememberKey(username));
      return v ? decodeURIComponent(escape(atob(v))) : '';
    } catch (e) { return ''; }
  }

  function forgetPassword(username) {
    try { localStorage.removeItem(rememberKey(username)); } catch (e) { /* 忽略 */ }
  }

  function applyRememberedPassword() {
    var user = $('authUsername').value.trim() || state.authAccount || '';
    if (!user) return false;
    var pw = loadPassword(user);
    if (!pw) return false;
    $('authPassword').value = pw;
    return true;
  }

  function autoLoginEnabled() {
    try { return localStorage.getItem('chris-auto-login') === '1'; } catch (e) { return false; }
  }

  function maybeAutoLogin() {
    if (!autoLoginEnabled()) return;
    var user = $('authUsername').value.trim() || state.authAccount || (loadAccounts()[0] || {}).username || '';
    if (!user) return;
    if (!state.authAccount) pickAccount(user);
    if (!applyRememberedPassword()) return;
    $('authSub').textContent = '正在自动登录…';
    setTimeout(function () { submitAuth(new Event('submit')); }, 150);
  }

  function modalForgotPassword() {
    openModal('忘记密码',
      '<p class="auth-hint">这个应用没有邮箱 / 短信找回，密码只能由管理员重置：</p>' +
      '<ol class="auth-steps">' +
        '<li>找管理员打开后台管理页面（在浏览器里打开这个服务的 /admin.html）</li>' +
        '<li>在「用户」里找到你的账号，点「重置密码」</li>' +
        '<li>拿到新密码后回来登录，再在「修改资料」里改成自己的</li>' +
      '</ol>',
      '<button class="btn-primary" id="forgotOk">知道了</button>');
    $('forgotOk').addEventListener('click', closeModal);
  }

  /* 设备确认登录（仿 QQ 扫码登录） */

  function pairStopPolling() {
    if (state.pairTimer) { clearInterval(state.pairTimer); state.pairTimer = null; }
    state.pairing = false;
  }

  function openPairPanel() {
    var panel = $('authPair');
    if (!panel) return;
    $('authForm').hidden = true;
    $('authAccounts').hidden = true;
    $('authFoot').hidden = true;
    panel.hidden = false;
    $('authSub').textContent = '在已登录的设备上确认';
    api('/pair/start', { method: 'POST' })
      .then(function (data) {
        var url = location.origin + '/?pair=' + data.code;
        $('authPairCode').textContent = data.code;
        $('authPairUrl').textContent = url;
        $('authPairStatus').textContent = '等待对方确认…（' + data.expiresIn + ' 秒内有效）';
        state.pairing = true;
        state.pairCode = data.code;
        state.pairTimer = setInterval(pollPair, 2000);
      })
      .catch(function (err) { toast(err.message, 'error'); closePairPanel(); });
  }

  function pollPair() {
    if (!state.pairing || !state.pairCode) return;
    api('/pair/status?code=' + encodeURIComponent(state.pairCode))
      .then(function (data) {
        if (data.status === 'pending') return;
        pairStopPolling();
        if (data.status === 'approved') {
          $('authPairStatus').textContent = '已确认，正在登录…';
          closePairPanel();
          return boot();
        }
        $('authPairStatus').textContent = '登录码过期了，点「返回登录」重新来一次';
      })
      .catch(function () { /* 网络抖动就下次再问 */ });
  }

  function closePairPanel() {
    pairStopPolling();
    state.pairCode = null;
    var panel = $('authPair');
    if (panel) panel.hidden = true;
    $('authForm').hidden = false;
    $('authFoot').hidden = false;
    renderAuthAccounts();
    setAuthMode(state.authMode || 'login');
  }

  /** 已登录的人打开 /?pair=CODE 时的确认卡片 */
  function confirmPairLogin(code) {
    if (!code) return;
    openModal('确认登录',
      '<p class="auth-hint">有一台设备正在用登录码 <b>' + esc(code) + '</b> 请求登录。确认后，那台设备会直接以你的账号（' + esc(state.me.nickname) + '）登录。</p>' +
      '<p class="auth-hint">如果不是你本人操作，点「不是我」。</p>',
      '<button class="btn-ghost" id="pairReject">不是我</button>' +
      '<button class="btn-primary" id="pairOk">确认登录</button>');
    $('pairReject').addEventListener('click', function () {
      closeModal();
      toast('已忽略这次登录请求');
    });
    $('pairOk').addEventListener('click', function () {
      var btn = this;
      btn.disabled = true;
      api('/pair/approve', { method: 'POST', body: JSON.stringify({ code: code }) })
        .then(function () { closeModal(); toast('已确认，那台设备正在登录'); })
        .catch(function (err) { toast(err.message, 'error'); })
        .then(function () { btn.disabled = false; });
    });
  }

  function handlePairFromUrl() {
    var code = '';
    try { code = new URLSearchParams(location.search).get('pair') || ''; } catch (e) { code = ''; }
    if (!code) return;
    state.pendingPairCode = code;
    try { history.replaceState(null, '', location.pathname); } catch (e) { /* 忽略 */ }
    if (state.me) confirmPairLogin(code);
    else toast('先登录你自己的账号，再来确认这次登录');
  }

  /* ------------------------------------------- 登录页的账号头像（QQ 那样） */

  function loadAccounts() {
    try {
      var raw = JSON.parse(localStorage.getItem('chris-accounts') || '[]');
      return Array.isArray(raw) ? raw.filter(function (x) { return x && x.username; }) : [];
    } catch (e) { return []; }
  }

  /** 登录成功后把「账号 + 昵称 + 头像」记下来，下次打开登录页就能看到各自的头像 */
  function saveAccount(user) {
    if (!user || !user.username) return;
    var list = loadAccounts().filter(function (x) { return x.username !== user.username; });
    list.unshift({
      username: user.username,
      nickname: user.nickname || user.username,
      avatar: String(user.avatar || '').slice(0, 400000),
      ts: Date.now()
    });
    try { localStorage.setItem('chris-accounts', JSON.stringify(list.slice(0, 4))); } catch (e) { /* 忽略 */ }
  }

  function currentAccount() {
    if (!state.authAccount) return null;
    return loadAccounts().filter(function (x) { return x.username === state.authAccount; })[0] || null;
  }

  /** 选了某个账号就把登录页顶部的大图标换成它的头像 */
  function applyAuthAvatar() {
    var box = $('authLogo');
    if (!box) return;
    var acc = currentAccount();
    if (acc) {
      // 选了账号就显示这个账号的头像：有图片用图片，没有就用昵称首字（QQ 也是这样）
      box.innerHTML = acc.avatar
        ? '<img src="' + esc(acc.avatar) + '" alt="">'
        : esc(initials(acc.nickname || acc.username));
      box.classList.add('is-account');
      box.classList.toggle('has-image', !!acc.avatar);
      box.dataset.accountFace = acc.username;
      return;
    }
    if (box.dataset.accountFace) {
      delete box.dataset.accountFace;
      box.classList.remove('is-account');
      if (state.branding && state.branding.logo) {
        box.innerHTML = '<img src="' + esc(state.branding.logo) + '" alt="">';
        box.classList.add('has-image');
      } else {
        box.innerHTML = '';
        box.classList.remove('has-image');
      }
    }
  }

  function renderAuthAccounts() {
    var box = $('authAccounts');
    if (!box) return;
    var list = loadAccounts();
    if (!list.length) {
      // 换设备 / 第一次打开：这里本来是空的，给个说明，免得以为账号丢了
      box.hidden = false;
      box.classList.add('is-hint');
      box.innerHTML = '<p class="auth-first-hint">这台设备第一次登录：直接输入你的<b>账号</b>和<b>密码</b>就行。<br>' +
        '账号都保存在服务器上，换设备 / 换浏览器都不会丢。</p>';
      return;
    }
    box.classList.remove('is-hint');
    box.hidden = false;
    box.innerHTML = list.map(function (acc) {
      var active = state.authAccount === acc.username;
      return '<button type="button" class="auth-account' + (active ? ' is-active' : '') + '" data-account="' + esc(acc.username) + '">' +
        '<span class="auth-account-face">' +
          (acc.avatar ? '<img src="' + esc(acc.avatar) + '" alt="">' : esc(initials(acc.nickname))) +
        '</span>' +
        '<span class="auth-account-main">' +
          '<span class="auth-account-name">' + esc(acc.nickname) + '</span>' +
          '<span class="auth-account-user">@' + esc(acc.username) + '</span>' +
        '</span>' +
        (active ? '<span class="auth-account-tick">✓</span>' : '') +
      '</button>';
    }).join('') + '<button type="button" class="auth-account-other" id="authOtherBtn">使用其他账号</button>';
  }

  function pickAccount(username) {
    state.authAccount = username;
    setAuthMode('login');
    $('authUsername').value = username;
    var field = $('authUsername').closest('.field');
    if (field) field.hidden = true;
    $('authSub').textContent = '输入密码后开始聊天';
    $('authPassword').value = '';
    applyRememberedPassword();
    applyAuthAvatar();
    renderAuthAccounts();
    $('authPassword').focus();
  }

  function clearPickedAccount() {
    state.authAccount = null;
    var field = $('authUsername').closest('.field');
    if (field) field.hidden = false;
    $('authUsername').value = '';
    setAuthMode('login');
    applyAuthAvatar();
    renderAuthAccounts();
    $('authUsername').focus();
  }

  /* 注册页的图形验证码（仿 QQ 注册页那行验证码） */

  function loadCaptcha() {
    var box = $('authCaptchaImg');
    if (!box) return;
    box.innerHTML = '<span class="auth-captcha-loading">…</span>';
    $('authCaptcha').value = '';
    api('/captcha').then(function (data) {
      state.captchaId = data.id;
      box.innerHTML = data.svg;
      // 强制放大验证码（之前被别的样式压到 16px 高，字母看不清）
      try {
        var svg = box.querySelector('svg');
        if (svg) {
          svg.setAttribute('width', '152');
          svg.setAttribute('height', '46');
          svg.style.setProperty('width', '152px', 'important');
          svg.style.setProperty('height', '46px', 'important');
          svg.style.setProperty('flex', 'none', 'important');
        }
        box.style.setProperty('width', '152px', 'important');
        box.style.setProperty('height', '46px', 'important');
        box.style.setProperty('flex', 'none', 'important');
        var inp = document.getElementById('authCaptcha');
        if (inp) inp.style.setProperty('padding-right', '166px', 'important');
      } catch (e) { /* 忽略 */ }
    }).catch(function () {
      box.innerHTML = '<span class="auth-captcha-loading">点我重试</span>';
    });
  }

  function modalDoc(kind) {
    var terms = [
      '<p>本应用是自建的聊天服务，用于你和朋友之间聊天、发朋友圈、语音通话。</p>',
      '<p>请不要用它发送违法内容、骚扰他人，或上传你有权属争议的文件。</p>',
      '<p>聊天记录保存在服务器上的 <code>data/</code> 目录里，管理员可以查看和删除。</p>'
    ].join('');
    var privacy = [
      '<p>注册只需要用户名和密码，我们不收集手机号、邮箱或身份信息。</p>',
      '<p>如果勾选「记住密码」，密码会以混淆形式保存在你自己的浏览器里，不会上传。</p>',
      '<p>头像、朋友圈图片等由你主动上传的内容会保存在服务器上，供其他用户查看。</p>'
    ].join('');
    openModal(kind === 'terms' ? '服务协议' : '隐私政策',
      '<div class="doc-text">' + (kind === 'terms' ? terms : privacy) + '</div>',
      '<button class="btn-primary" id="docOk">知道了</button>');
    $('docOk').addEventListener('click', closeModal);
  }

  function setAuthMode(mode) {
    state.authMode = mode;
    if (mode === 'register') {
      state.authAccount = null;
      var f = $('authUsername').closest('.field');
      if (f) f.hidden = false;
      applyAuthAvatar();
      renderAuthAccounts();
    }
    document.querySelectorAll('.auth-tab').forEach(function (t) {
      t.classList.toggle('is-active', t.getAttribute('data-auth-tab') === mode);
    });
    var isReg = mode === 'register';
    $('authForm').classList.toggle('is-register', isReg);   // 注册模式才显示字段标签
    document.querySelector('.auth-card').classList.toggle('is-register', isReg);
    // 注册模式不显示「用过的账号」列表（QQ 注册页也没有），否则会把底部内容挤出卡片
    if ($('authAccounts')) $('authAccounts').hidden = isReg;
    if ($('phoneField')) $('phoneField').hidden = !isReg;
    if ($('genderField')) $('genderField').hidden = !isReg;
    if ($('pwHint')) $('pwHint').hidden = !isReg;
    if ($('captchaField')) $('captchaField').hidden = !isReg;
    if ($('authAgreeRow')) $('authAgreeRow').hidden = !isReg;
    if ($('authRemember') && $('authRemember').closest('.auth-check')) $('authRemember').closest('.auth-check').hidden = isReg;
    if ($('authAuto') && $('authAuto').closest('.auth-check')) $('authAuto').closest('.auth-check').hidden = isReg;
    if ($('authForgot')) $('authForgot').hidden = isReg;
    if (isReg) loadCaptcha();
    var nickField = $('nicknameField');
    // 用 visibility 而不是 hidden：切到登录时昵称行仍然占位，输入框不会上下跳
    nickField.hidden = false;
    nickField.classList.toggle('is-off', mode !== 'register');
    nickField.querySelector('input').disabled = mode !== 'register';
    $('authSubmit').textContent = mode === 'login' ? '登录' : '立即注册';
    $('authSub').textContent = mode === 'login' ? '登录后开始聊天' : '创建一个账号，马上就能聊天';
    var foot = $('authFoot');
    if (foot) {
      foot.innerHTML = mode === 'login'
        ? '还没有账号？<b data-auth-tab="register">立即注册</b>'
        : '已有账号？<b data-auth-tab="login">立即登录</b>';
    }
    $('authError').hidden = true;
  }

  /* ------------------------------------------------------ 后台可配的界面图标 */

  var DEFAULT_ICON_HTML = null;

  function captureDefaultIcons() {
    if (DEFAULT_ICON_HTML) return;
    DEFAULT_ICON_HTML = {};
    document.querySelectorAll('.rail-item').forEach(function (item) {
      var key = item.getAttribute('data-panel') || 'account';
      var svg = item.querySelector('svg');
      DEFAULT_ICON_HTML[key] = svg ? svg.outerHTML : '';
    });
  }


  /* ---------------------------------------- 后台可配的字号 / 主色 / 文字颜色 */

  function hexToRgb(hex) {
    var m = /^#([0-9a-f]{6})$/i.exec(String(hex || '').trim());
    if (!m) return null;
    var n = parseInt(m[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }

  function mixWhite(hex, amount) {
    var rgb = hexToRgb(hex);
    if (!rgb) return hex;
    return '#' + rgb.map(function (c) {
      var v = Math.round(c + (255 - c) * amount);
      return ('0' + v.toString(16)).slice(-2);
    }).join('');
  }

  /** 颜色对比度，用来判断主色上该用白字还是深色字 */
  function contrastWithWhite(hex) {
    var rgb = hexToRgb(hex);
    if (!rgb) return 21;
    function f(v) { v = v / 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
    var l = 0.2126 * f(rgb[0]) + 0.7152 * f(rgb[1]) + 0.0722 * f(rgb[2]);
    return (1.05) / (l + 0.05);
  }

  function applyAppearance(branding) {
    var accent = (branding && branding.accentColor) ? String(branding.accentColor).trim() : '';
    var ink = (branding && branding.textColor) ? String(branding.textColor).trim() : '';
    var scale = Number((branding && branding.fontScale) || 0) || 1;
    if (!hexToRgb(accent)) accent = '';
    if (!hexToRgb(ink)) ink = '';

    var styleEl = document.getElementById('brand-colors');
    if (!styleEl) {
      styleEl = document.createElement('style');
      styleEl.id = 'brand-colors';
      document.head.appendChild(styleEl);
    }
    var css = '';
    if (accent) {
      var rgb = hexToRgb(accent);
      var hover = mixWhite(accent, 0.14);
      var soft = 'rgba(' + rgb.join(', ') + ', ';
      css += ':root{--qq:' + accent + ';--qq-hover:' + hover + ';--bubble-me:' + accent + ';--qq-soft:' + soft + '.12);}\n';
      css += ':root[data-theme="dark"]{--qq:' + accent + ';--qq-hover:' + hover + ';--bubble-me:' + accent + ';--qq-soft:' + soft + '.18);}\n';
      if (contrastWithWhite(accent) < 2.0) {
        css += '.msg.me .bubble,.btn-primary,.send-btn,.comment-bar button{color:#12141a;}\n';
      }
    }
    if (ink) {
      css += ':root{--ink:' + ink + ';}\n:root[data-theme="dark"]{--ink:#eef0f4;}\n';
    }
    styleEl.textContent = css;

    var root = document.documentElement;
    if (scale && scale !== 1) root.style.setProperty('--font-scale', String(scale));
    else root.style.removeProperty('--font-scale');
  }

  function applyCustomFont(branding) {
    var fam = (branding && branding.fontFamily) ? String(branding.fontFamily).trim() : '';
    var url = (branding && branding.fontUrl) ? String(branding.fontUrl) : '';
    var styleEl = document.getElementById('brand-font-face');
    if (!styleEl) {
      styleEl = document.createElement('style');
      styleEl.id = 'brand-font-face';
      document.head.appendChild(styleEl);
    }
    if (url) {
      styleEl.textContent = '@font-face{font-family:"CHRIS Custom UI";src:url("' + url + '");font-display:swap;}';
      fam = '"CHRIS Custom UI"' + (fam ? ', ' + fam : '');
    } else {
      styleEl.textContent = '';
    }
    var root = document.documentElement;
    if (fam) {
      root.style.setProperty('--font-ui', fam + ', "Segoe UI", "Microsoft YaHei UI", "Microsoft YaHei", Arial, sans-serif');
    } else {
      root.style.removeProperty('--font-ui');
    }
  }

  function applyBranding(branding) {
    if (!branding) return;
    captureDefaultIcons();
    state.branding = branding;

    var name = branding.appName || 'CHRIS Chat';
    state.appName = name;
    updateTitle();
    $('authTitle').textContent = name;
    /* 登录页左边那块品牌名也跟着应用名走 */
    if ($('authBrandName')) $('authBrandName').textContent = name;

    // favicon 与登录页 Logo
    if (branding.logo) {
      $('authLogo').innerHTML = '<img src="' + esc(branding.logo) + '" alt="">';
      $('authLogo').classList.add('has-image');
    } else {
      $('authLogo').classList.remove('has-image');
    }
    // 标签页/窗口左上角那个图标去掉（始终留空）
    if ($('favicon')) $('favicon').setAttribute('href', 'data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22/%3E');
    applyAuthAvatar();   // 选了某个账号的话，登录页顶部显示的是这个账号的头像

    // 左侧竖栏图标
    var icons = branding.icons || {};
    document.querySelectorAll('.rail-item').forEach(function (item) {
      var key = item.getAttribute('data-panel') || 'account';
      var custom = icons[key];
      var svg = item.querySelector('svg');
      var img = item.querySelector('.rail-icon-img');
      if (custom) {
        if (!img) {
          img = document.createElement('img');
          img.className = 'rail-icon-img';
          img.alt = '';
          item.insertBefore(img, item.firstChild);
        }
        img.src = custom;
        img.style.display = '';
        if (svg) svg.style.display = 'none';
      } else {
        if (img) img.style.display = 'none';
        if (svg) svg.style.display = '';
      }
    });
    applyChatBackground();
    applyCustomFont(branding);
    applyAppearance(branding);
  }

  function loadBranding() {
    return api('/branding').then(function (data) {
      applyBranding(data.branding);
    }).catch(function () { /* 取不到就用默认 */ });
  }

  /* ------------------------------------------------------------ 聊天背景 */

  var CHAT_BG_PRESETS = [
    'linear-gradient(180deg, #f5f6f8 0%, #eef1f5 100%)',
    'linear-gradient(180deg, #eaf4ff 0%, #dcecff 100%)',
    'linear-gradient(180deg, #fdf2f8 0%, #fce7f3 100%)',
    'linear-gradient(180deg, #f0fdf4 0%, #dcfce7 100%)',
    'linear-gradient(180deg, #fefce8 0%, #fef3c7 100%)',
    'linear-gradient(180deg, #f5f3ff 0%, #ede9fe 100%)'
  ];

  var CHAT_BG_AUTO = {
    light: 'linear-gradient(180deg, #f5f6f8 0%, #eef1f5 100%)',
    dark: 'linear-gradient(180deg, #1b1c21 0%, #121317 100%)'
  };

  function currentEffectiveTheme() {
    var attr = document.documentElement.getAttribute('data-theme');
    if (attr === 'dark' || attr === 'light') return attr;
    return effectiveTheme(currentThemeMode());
  }

  function chatBgShorthand(value) {
    if (!value) return '';
    if (value === 'auto') return CHAT_BG_AUTO[currentEffectiveTheme()] || CHAT_BG_AUTO.light;
    if (value.indexOf('preset:') === 0) {
      return CHAT_BG_PRESETS[Number(value.split(':')[1])] || '';
    }
    return 'url("' + value + '") center / cover no-repeat';
  }

  function applyChatBackground() {
    var el = $('messages');
    if (!el) return;
    var value = (state.me && state.me.chatBackground) ||
      (state.branding && state.branding.chatBackground) || '';
    var css = chatBgShorthand(value);
    el.style.background = css;
    el.classList.toggle('has-custom-bg', !!css);
  }

  function renderChatBgPreview() {
    var box = $('chatBgPreview');
    if (!box) return;
    var draft = state.chatBgDraft || '';
    box.style.background = chatBgShorthand(draft) || CHAT_BG_PRESETS[0];
    $('chatBgLabel').textContent = !draft ? '默认背景'
      : (draft === 'auto' ? '跟随系统（浅色 / 深色自动切换）'
        : (draft.indexOf('preset:') === 0 ? '预设背景' : '自定义图片'));
    document.querySelectorAll('.bg-preset').forEach(function (b) {
      var id = b.getAttribute('data-bg');
      b.classList.toggle('is-active', draft === (id === 'auto' ? 'auto' : 'preset:' + id));
    });
  }

  function openChatBgEditor() {
    state.chatBgDraft = (state.me && state.me.chatBackground) || '';
    openModal('聊天背景',
      '<div class="chat-bg-preview" id="chatBgPreview"><span id="chatBgLabel"></span></div>' +
      '<div class="field"><span class="field-label">上传自己的图片</span>' +
      '<input type="file" id="chatBgFile" accept="image/*"></div>' +
      '<div class="field"><span class="field-label">或者选一套预设</span>' +
      '<div class="bg-presets">' +
        '<button type="button" class="bg-preset bg-preset-auto" data-bg="auto" title="跟随系统（浅色 / 深色自动切换）"><span>跟随系统</span></button>' +
        CHAT_BG_PRESETS.map(function (g, i) {
          return '<button type="button" class="bg-preset" data-bg="' + i + '" style="background:' + g + '"></button>';
        }).join('') +
      '</div></div>' +
      '<p class="auth-hint">背景只对你自己的界面生效，不会影响对方。后台设置的默认背景在你自己没设置时生效。</p>',
      '<button class="btn-ghost" id="chatBgReset">恢复默认</button>' +
      '<button class="btn-primary" id="chatBgSave">保存背景</button>');
    renderChatBgPreview();

    document.querySelector('.bg-presets').addEventListener('click', function (e) {
      var btn = e.target.closest('[data-bg]');
      if (!btn) return;
      var bgId = btn.getAttribute('data-bg');
      state.chatBgDraft = bgId === 'auto' ? 'auto' : 'preset:' + bgId;
      if (bgId === 'auto') toast('跟随系统：浅色模式用浅色背景，深色模式用深背景');
      renderChatBgPreview();
    });

    $('chatBgReset').addEventListener('click', function () {
      state.chatBgDraft = '';
      renderChatBgPreview();
    });

    $('chatBgFile').addEventListener('change', function (e) {
      var file = e.target.files && e.target.files[0];
      if (!file) return;
      if (file.size > 8 * 1024 * 1024) return toast('图片不能超过 8MB', 'error');
      var reader = new FileReader();
      reader.onload = function () {
        api('/upload', { method: 'POST', body: JSON.stringify({ dataUrl: String(reader.result), filename: file.name }) })
          .then(function (d) {
            state.chatBgDraft = d.url;
            renderChatBgPreview();
            toast('图片已上传，点保存生效');
          })
          .catch(function (err) { toast(err.message, 'error'); });
      };
      reader.readAsDataURL(file);
      e.target.value = '';
    });

    $('chatBgSave').addEventListener('click', function () {
      var btn = this;
      btn.disabled = true;
      api('/me', { method: 'PATCH', body: JSON.stringify({ chatBackground: state.chatBgDraft || '' }) })
        .then(function (data) {
          state.me = data.user;
          applyChatBackground();
          closeModal();
          toast(state.me.chatBackground ? '聊天背景已更新' : '已恢复默认背景');
        })
        .catch(function (err) { toast(err.message, 'error'); })
        .then(function () { btn.disabled = false; });
    });
  }

  /* --------------------------------------------------------- 账号菜单 */

  /* ---------------------------------------------------------- 主题切换 */

  function effectiveTheme(mode) {
    if (mode === 'system') {
      return (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light';
    }
    return mode === 'dark' ? 'dark' : 'light';
  }

  function currentThemeMode() {
    try { return localStorage.getItem('chris-theme') || 'light'; } catch (e) { return 'light'; }
  }

  function applyTheme(mode) {
    var m = (mode === 'dark' || mode === 'light' || mode === 'system') ? mode : 'system';
    try { localStorage.setItem('chris-theme', m); } catch (e) { /* 忽略 */ }
    var eff = effectiveTheme(m);
    document.documentElement.setAttribute('data-theme', eff);
    document.documentElement.style.colorScheme = eff;
    document.querySelectorAll('[data-theme-opt]').forEach(function (b) {
      b.classList.toggle('is-active', b.getAttribute('data-theme-opt') === m);
    });
    applyChatBackground();
    renderTopbar();
  }

  function setupTheme() {
    applyTheme(currentThemeMode());
    var mq = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
    if (mq) {
      var onChange = function () { if (currentThemeMode() === 'system') applyTheme('system'); };
      if (mq.addEventListener) mq.addEventListener('change', onChange);
      else if (mq.addListener) mq.addListener(onChange);
    }
    var seg = $('themeSeg');
    if (seg) {
      seg.addEventListener('click', function (e) {
        var btn = e.target.closest('[data-theme-opt]');
        if (btn) applyTheme(btn.getAttribute('data-theme-opt'));
      });
    }
  }

  /* -------------------------------------------- 更多菜单（在线状态 / 通知） */

  function statusLabel(userId) {
    if (!state.online[userId]) return '离线';
    var st = state.statuses[userId] || 'online';
    if (st === 'busy') return '忙碌';
    if (st === 'away') return '离开';
    if (st === 'invisible' || st === 'offline') return '离线';
    return '在线';
  }

  function statusKey(userId) {
    if (!state.online[userId]) return 'offline';
    return state.statuses[userId] || 'online';
  }

  function applyStatusDot(el, key) {
    if (!el) return;
    el.classList.toggle('is-online', key === 'online');
    el.classList.toggle('is-busy', key === 'busy');
    el.classList.toggle('is-away', key === 'away');
  }

  function prefillNotifyPrefs() {
    var notify = false, dnd = false;
    try { notify = localStorage.getItem('chris-notify') === '1'; dnd = localStorage.getItem('chris-dnd') === '1'; } catch (e) { /* 忽略 */ }
    if ($('meNotifyToggle')) $('meNotifyToggle').checked = notify;
    if ($('meDndToggle')) $('meDndToggle').checked = dnd;
  }

  function dndOn() {
    try { return localStorage.getItem('chris-dnd') === '1'; } catch (e) { return false; }
  }

  function notifyOn() {
    try { return localStorage.getItem('chris-notify') === '1'; } catch (e) { return false; }
  }

  function renderStatusPicker() {
    var st = (state.me && state.me.status) || 'online';
    var txt = st === 'busy' ? '忙碌' : (st === 'away' ? '离开' : (st === 'invisible' ? '隐身' : '在线'));
    if ($('meStatusText')) $('meStatusText').textContent = txt;
    applyStatusDot($('meStatusDot'), st);
    if ($('meMenuAvatar')) {
      $('meMenuAvatar').innerHTML = state.me && state.me.avatar
        ? '<img src="' + esc(state.me.avatar) + '" alt="">'
        : esc(initials((state.me && state.me.nickname) || '?'));
    }
    document.querySelectorAll('#meStatusRow [data-status]').forEach(function (b) {
      b.classList.toggle('is-active', b.getAttribute('data-status') === st);
    });
  }

  function setMyStatus(st) {
    api('/me/status', { method: 'POST', body: JSON.stringify({ status: st }) })
      .then(function () {
        if (state.me) state.me.status = st;
        renderStatusPicker();
        var label = st === 'busy' ? '忙碌' : (st === 'away' ? '离开' : (st === 'invisible' ? '隐身' : '在线'));
        toast('在线状态已切换为「' + label + '」');
      })
      .catch(function (err) { toast(err.message, 'error'); });
  }

  /** 新消息的桌面通知（QQ 那种右下角弹窗），免打扰时不出 */
  function notifyDesktop(title, body) {
    if (!notifyOn() || dndOn()) return;
    if (typeof Notification === 'undefined' || Notification.permission !== 'granted') return;
    if (!document.hidden) return;   // 页面在前台就不用弹了
    try {
      var n = new Notification(title, { body: body, tag: 'chris-chat' });
      n.onclick = function () { try { window.focus(); n.close(); } catch (e) { /* 忽略 */ } };
    } catch (e) { /* 忽略 */ }
  }

  function modalSettings() {
    openModal('设置',
      '<div class="settings-block"><div class="settings-label">外观</div>' +
        '<div class="settings-theme" id="settingsTheme"></div></div>' +
      '<div class="settings-block"><div class="settings-label">聊天背景</div>' +
        '<p class="auth-hint">换背景、上传自己的图，只影响你自己的界面。</p>' +
        '<button class="btn-ghost" id="settingsChatBg">打开聊天背景设置</button></div>' +
      '<div class="settings-block"><div class="settings-label">消息提醒</div>' +
        '<label class="me-switch"><input type="checkbox" id="settingsNotify"><span>新消息桌面通知</span></label>' +
        '<label class="me-switch"><input type="checkbox" id="settingsDnd"><span>免打扰</span></label></div>',
      '<button class="btn-primary" id="settingsOk">完成</button>');
    // 主题三选
    var box = $('settingsTheme');
    var cur = currentThemeMode();
    box.innerHTML = [['light', '浅色'], ['dark', '深色'], ['system', '跟随系统']].map(function (o) {
      return '<button type="button" class="settings-theme-btn' + (cur === o[0] ? ' is-active' : '') + '" data-theme-pick="' + o[0] + '">' + o[1] + '</button>';
    }).join('');
    box.addEventListener('click', function (e) {
      var b = e.target.closest('[data-theme-pick]');
      if (!b) return;
      applyTheme(b.getAttribute('data-theme-pick'));
      box.querySelectorAll('[data-theme-pick]').forEach(function (x) {
        x.classList.toggle('is-active', x === b);
      });
    });
    $('settingsNotify').checked = notifyOn();
    $('settingsDnd').checked = dndOn();
    $('settingsNotify').addEventListener('change', function () {
      requestNotify(this.checked);
      if ($('meNotifyToggle')) $('meNotifyToggle').checked = this.checked;
    });
    $('settingsDnd').addEventListener('change', function () {
      try { localStorage.setItem('chris-dnd', this.checked ? '1' : '0'); } catch (e) { /* 忽略 */ }
      if ($('meDndToggle')) $('meDndToggle').checked = this.checked;
      toast(this.checked ? '已开启免打扰' : '已关闭免打扰');
    });
    $('settingsChatBg').addEventListener('click', function () { closeModal(); setTimeout(openChatBgEditor, 120); });
    $('settingsOk').addEventListener('click', closeModal);
  }

  function requestNotify(on) {
    function setPref(okk, msg, tone) {
      try { localStorage.setItem('chris-notify', okk ? '1' : '0'); } catch (e) { /* 忽略 */ }
      if ($('meNotifyToggle')) $('meNotifyToggle').checked = okk;
      if ($('settingsNotify')) $('settingsNotify').checked = okk;
      if (msg) toast(msg, tone);
    }
    if (!on) { setPref(false, '已关闭桌面通知'); return; }
    if (typeof Notification === 'undefined') { setPref(false, '这个浏览器不支持桌面通知', 'error'); return; }
    if (Notification.permission === 'granted') { setPref(true, '桌面通知已开启'); return; }
    if (Notification.permission === 'denied') { setPref(false, '浏览器已禁止通知：点地址栏左边的图标允许后再试', 'error'); return; }
    var settled = false;
    Notification.requestPermission().then(function (p) {
      settled = true;
      if (p === 'granted') setPref(true, '桌面通知已开启');
      else setPref(false, '没有拿到通知权限，开关已还原', 'error');
    }).catch(function () { settled = true; setPref(false, '通知权限申请失败', 'error'); });
    // 有的浏览器把权限弹窗挂起了（比如无头模式），别让开关一直假装是开的
    setTimeout(function () {
      if (settled) return;
      if (Notification.permission !== 'granted') setPref(false, '通知权限还没确认，开关已还原', 'error');
    }, 3500);
  }

  function modalAbout() {
    var name = (state.branding && state.branding.appName) || 'CHRIS Chat';
    api('/version').then(function (v) {
      openModal('关于',
        '<div class="about-box">' +
          '<div class="about-logo">' + (state.branding && state.branding.logo ? '<img src="' + esc(state.branding.logo) + '" alt="">' : '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2C6.5 2 2 5.8 2 10.5c0 2.7 1.5 5.1 3.9 6.6L5 21l4-2.1c1 .2 2 .3 3 .3 5.5 0 10-3.8 10-8.7S17.5 2 12 2z"/></svg>') + '</div>' +
          '<div class="about-name">' + esc(name) + '</div>' +
          '<div class="about-line">前端版本 ' + esc(String(v.version || '-').slice(0, 8)) + '</div>' +
          '<div class="about-line">数据保存在服务器的 <code>data/</code> 目录</div>' +
        '</div>',
        '<button class="btn-primary" id="aboutOk">知道了</button>');
      $('aboutOk').addEventListener('click', closeModal);
    }).catch(function () {
      openModal('关于', '<p class="auth-hint">' + esc(name) + '</p>', '<button class="btn-primary" id="aboutOk">知道了</button>');
      $('aboutOk').addEventListener('click', closeModal);
    });
  }

  function setupAccountMenu() {
    var menu = $('meMenu');
    var btn = $('meMenuBtn');

    function closeMenu() {
      menu.hidden = true;
      btn.setAttribute('aria-expanded', 'false');
    }

    btn.addEventListener('click', function (e) {
      e.stopPropagation();
      if (menu.hidden) {
        menu.hidden = false;
        btn.setAttribute('aria-expanded', 'true');
        renderStatusPicker();
        prefillNotifyPrefs();
        if (state.refreshVersionLabel) state.refreshVersionLabel();
      } else {
        closeMenu();
      }
    });

    menu.addEventListener('click', function (e) {
      var item = e.target.closest('[data-menu]');
      if (!item) return;
      closeMenu();
      var action = item.getAttribute('data-menu');
      if (action === 'profile') modalProfile();
      else if (action === 'security') modalSecurity();
      else if (action === 'phone') modalPhoneAccess();
      else if (action === 'settings') modalSettings();
      else if (action === 'about') modalAbout();
      else if (action === 'chatbg') openChatBgEditor();
      else if (action === 'switch') doLogout('switch');
      else if (action === 'logout') doLogout('logout');
    });

    document.addEventListener('click', function (e) {
      if (!e.target.closest('.me-menu-wrap')) closeMenu();
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') closeMenu();
    });

    // 在线状态选择
    var statusRow = $('meStatusRow');
    if (statusRow) {
      statusRow.addEventListener('click', function (e) {
        var b2 = e.target.closest('[data-status]');
        if (b2) setMyStatus(b2.getAttribute('data-status'));
      });
    }
    if ($('meCheckUpdate')) {
      $('meCheckUpdate').addEventListener('click', function () {
        api('/version').then(function (d) {
          if (d && d.version && d.version !== state.loadedVersion) {
            toast('发现新版本，正在刷新…');
            setTimeout(function () { location.reload(); }, 300);
          } else {
            toast('已经是最新版本');
          }
        }).catch(function () { toast('检查更新失败，网络不通？', 'error'); });
      });
    }
    if ($('meNotifyToggle')) {
      $('meNotifyToggle').addEventListener('change', function () { requestNotify(this.checked); });
    }
    if ($('meDndToggle')) {
      $('meDndToggle').addEventListener('change', function () {
        try { localStorage.setItem('chris-dnd', this.checked ? '1' : '0'); } catch (e2) { /* 忽略 */ }
        toast(this.checked ? '已开启免打扰' : '已关闭免打扰');
      });
    }
  }

  function doLogout(mode) {
    var isSwitch = mode === 'switch';
    var question = isSwitch
      ? '切换账号？\n当前账号会退出登录，之后你可以用另一个账号登录。'
      : '确定退出登录吗？';
    if (!window.confirm(question)) return;

    var finish = function () {
      // 主动退出 / 切换账号时取消「自动登录」，否则会被自动登回去（QQ 也是这个行为）
      try { localStorage.removeItem('chris-auto-login'); } catch (e) { /* 忽略 */ }
      try { if (socket) socket.close(); } catch (e) { /* 忽略 */ }
      socket = null;
      state.me = null;
      state.chats = [];
      state.friends = [];
      state.messages = {};
      state.activeChatId = null;
      try { sessionStorage.setItem('chris_auth_notice', isSwitch ? 'switch' : 'logout'); } catch (e) { /* 忽略 */ }
      window.location.reload();
    };

    api('/logout', { method: 'POST' }).then(finish).catch(finish);
  }

  function consumeAuthNotice() {
    var notice = null;
    try {
      notice = sessionStorage.getItem('chris_auth_notice');
      if (notice) sessionStorage.removeItem('chris_auth_notice');
    } catch (e) { /* 忽略 */ }
    var box = $('authNotice');
    if (!notice) { box.hidden = true; return; }
    box.hidden = false;
    box.textContent = notice === 'switch'
      ? '已退出当前账号，请用另一个账号登录。'
      : '已退出登录。';
    $('authError').hidden = true;
    $('authUsername').value = '';
    $('authPassword').value = '';
    $('authNickname').value = '';
  }

  function submitAuth(e) {
    if (e && e.preventDefault) e.preventDefault();
    var username = $('authUsername').value.trim();
    var password = $('authPassword').value;
    var nickname = $('authNickname').value.trim();
    var err = $('authError');

    function showError(msg) { err.hidden = false; err.textContent = msg; }
    if (!username || !password) return showError('请填写用户名和密码');
    if (state.authMode === 'register' && password.length < 6) return showError('密码至少 6 位');
    if (state.authMode === 'register') {
      var agree = $('authAgree');
      if (agree && !agree.checked) return showError('请先阅读并同意《服务协议》和《隐私政策》');
      if (!$('authCaptcha').value.trim()) return showError('请填写验证码');
    }
    err.hidden = true;

    var btn = $('authSubmit');
    btn.disabled = true;
    var path = state.authMode === 'login' ? '/login' : '/register';
    var payload = state.authMode === 'login'
      ? { username: username, password: password }
      : {
        username: username, password: password, nickname: nickname || username,
        phone: ($('authPhone') ? $('authPhone').value.trim() : ''),
        gender: state.authGender || '',
        captchaId: state.captchaId || '', captcha: $('authCaptcha').value.trim()
      };

    api(path, { method: 'POST', body: JSON.stringify(payload) })
      .then(function () {
        // 记住密码 / 自动登录
        if ($('authRemember') && $('authRemember').checked) savePassword(username, password);
        else forgetPassword(username);
        try {
          if ($('authAuto') && $('authAuto').checked) localStorage.setItem('chris-auto-login', '1');
          else localStorage.removeItem('chris-auto-login');
        } catch (e3) { /* 忽略 */ }
        // 先放登录的加载动画，至少显示 2 秒，再进主界面
        showBootLoader();
        var startedAt = Date.now();
        return boot().then(function () {
          var left = Math.max(0, 2000 - (Date.now() - startedAt));
          hideBootLoader(left);
        });
      })
      .catch(function (e2) {
        showError(e2.message);
        if (state.authMode === 'register') loadCaptcha();
      })
      .then(function () { btn.disabled = false; });
  }

  /* --------------------------------------------------------- WebSocket */

  /* ---------------- 登录后的加载动画（至少 2 秒） ---------------- */
  var bootTimer = null, bootHideTimer = null;

  function showBootLoader() {
    var el = $('bootLoader');
    if (!el) return;
    if ($('bootName')) $('bootName').textContent = state.appName || 'CHRIS Chat';
    clearTimeout(bootTimer); clearTimeout(bootHideTimer);
    el.classList.remove('is-out');
    el.hidden = false;
  }

  function hideBootLoader(delay) {
    var el = $('bootLoader');
    if (!el || el.hidden) return;
    clearTimeout(bootTimer);
    bootTimer = setTimeout(function () {
      el.classList.add('is-out');
      bootHideTimer = setTimeout(function () {
        el.hidden = true;
        el.classList.remove('is-out');
      }, 380);
    }, delay || 0);
  }

  function setConn(stateName, text) {
    var node = $('connState');
    node.setAttribute('data-state', stateName);
    $('connText').textContent = text;
  }

  function connect() {
    var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    try {
      socket = new WebSocket(proto + '//' + location.host);
    } catch (err) {
      return scheduleReconnect();
    }

    socket.onopen = function () {
      state.wsReady = true;
      reconnectDelay = 800;
      setConn('online', '已连接');
    };

    socket.onmessage = function (event) {
      var msg;
      try { msg = JSON.parse(event.data); } catch (err) { return; }
      handleWs(msg);
    };

    socket.onclose = function () {
      state.wsReady = false;
      setConn('offline', '连接断开，重连中…');
      scheduleReconnect();
    };

    socket.onerror = function () { /* onclose 会处理 */ };
  }

  function scheduleReconnect() {
    setTimeout(function () {
      if (state.me) connect();
    }, reconnectDelay);
    reconnectDelay = Math.min(reconnectDelay * 1.6, 8000);
  }

  function wsSend(payload) {
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify(payload));
      return true;
    }
    return false;
  }

  function handleWs(msg) {
    if (msg.type === 'ready') {
      state.online = {};
      state.online = {};
      (msg.online || []).forEach(function (id) { state.online[id] = true; });
      state.statuses = msg.statuses || {};
      setMomentBadge(msg.momentUnread || 0);
      render();
      return;
    }

    if (msg.type === 'call') { handleCallEvent(msg); return; }
    if (msg.type === 'call-error') {
      if (call) { callEls().status.textContent = msg.error; toast(msg.error, 'error'); callClose(1200); }
      else toast(msg.error, 'error');
      return;
    }

    if (msg.type === 'branding') {
      applyBranding(msg.branding);
      toast('界面图标已更新');
      return;
    }

    if (msg.type === 'moment') {
      if (msg.action === 'new') {
        var fitsHere = !state.momentUser || msg.moment.authorId === state.momentUser;
        if (fitsHere && !state.moments.some(function (x) { return x.id === msg.moment.id; })) {
          state.moments.unshift(msg.moment);
          if (state.panel === 'moments') renderMoments();
        }
        if (msg.authorId !== state.me.id) {
          if (state.panel === 'moments') {
            api('/moments/seen', { method: 'POST' }).catch(function () {});
          } else {
            setMomentBadge((state.momentUnread || 0) + 1);
            toast((msg.moment.author ? msg.moment.author.nickname : '好友') + ' 发布了新动态');
          }
        }
      } else if (msg.action === 'delete') {
        state.moments = state.moments.filter(function (x) { return x.id !== msg.momentId; });
        if (state.panel === 'moments') renderMoments();
      } else if (msg.action === 'like' || msg.action === 'comment') {
        if (state.panel === 'moments') {
          loadMoments(false).catch(function () {});
        }
      }
      return;
    }
    if (msg.type === 'presence') {
      state.online[msg.userId] = !!msg.online;
      state.statuses[msg.userId] = msg.status || (msg.online ? 'online' : 'offline');
      refreshHeadStatus();
      render();
      return;
    }
    if (msg.type === 'message') {
      var m = msg.message;
      if (!state.messages[m.chatId]) state.messages[m.chatId] = [];
      // 走 WS 发出去的消息，服务端会带着 clientId 回显：把本地那条「发送中」替换掉，
      // 否则界面上会同时留下「发送中」和服务端那条，等于同一条消息出现两次
      if (msg.clientId) {
        var pendingIdx = state.messages[m.chatId].findIndex(function (x) { return x.id === msg.clientId; });
        if (pendingIdx !== -1) state.messages[m.chatId].splice(pendingIdx, 1);
      }
      if (!state.messages[m.chatId].some(function (x) { return x.id === m.id; })) {
        state.messages[m.chatId].push(m);
      }
      if (msg.chat) upsertChat(msg.chat);
      // 只有这个会话真的显示在屏幕上才算已读；切到朋友圈/联系人时不该清掉未读
      var viewing = state.activeChatId === m.chatId && !$('chatPane').hidden;
      if (viewing) {
        renderMessages();
        markRead(m.chatId);
      } else if (m.senderId !== state.me.id) {
        var preview = m.kind === 'text' ? m.content.slice(0, 20)
          : (m.kind === 'image' ? '[图片]' : (m.kind === 'audio' ? '[语音]'
            : (m.kind === 'gift' ? ('[礼物] ' + giftInfo(m.content).name)
              : (m.kind === 'transfer' ? ('[转账] ¥' + (transferInfo(m.content).amount || 0).toFixed(2))
                : (m.kind === 'location' ? '[位置]' : '[文件]')))));
        if (!dndOn()) toast((msg.chat ? msg.chat.title : '新消息') + '：' + preview);
        notifyDesktop(msg.chat ? msg.chat.title : '新消息', preview);
      }
      return;
    }
    if (msg.type === 'recall') {
      var list = state.messages[msg.chatId] || [];
      list.forEach(function (x) { if (x.id === msg.messageId) x.recalled = true; });
      if (state.activeChatId === msg.chatId) renderMessages();
      return;
    }
    if (msg.type === 'shake') {
      shakeWindow();
      toast((msg.nickname || '对方') + ' 抖动了窗口！');
      return;
    }
    if (msg.type === 'typing') {
      state.typing[msg.chatId] = { name: msg.nickname, at: Date.now() };
      updateTyping();
      return;
    }
    if (msg.type === 'read') {
      if (state.activeChatId === msg.chatId) {
        state.lastPeerRead = msg.seq;
      }
      return;
    }
    if (msg.type === 'friend') {
      if (msg.action === 'request') toast(msg.user.nickname + ' 请求加你为好友');
      else toast('你和 ' + msg.user.nickname + ' 已成为好友');
      loadContacts();
      return;
    }
    if (msg.type === 'chat') {
      upsertChat(msg.chat);
      loadChats();
      if (msg.notice) toast(msg.notice);
      return;
    }
    if (msg.type === 'error') {
      toast(msg.error, 'error');
      if (msg.clientId && pending[msg.clientId]) {
        pending[msg.clientId].el.classList.add('is-failed');
      }
    }
  }

  /* --------------------------------------------------------------- 渲染 */

  function upsertChat(chat) {
    var idx = state.chats.findIndex(function (c) { return c.id === chat.id; });
    if (idx === -1) state.chats.unshift(chat);
    else state.chats[idx] = Object.assign({}, state.chats[idx], chat);
    state.chats.sort(function (a, b) { return String(b.updatedAt).localeCompare(String(a.updatedAt)); });
    renderChats();
  }

  /* ------------------------------------------------ 会话右键菜单（仿 QQ） */

  var ctxChatId = null;

  function openCtxMenu(chatId, x, y) {
    var menu = $('ctxMenu');
    if (!menu) return;
    var chat = state.chats.filter(function (c) { return c.id === chatId; })[0];
    if (!chat) return;
    ctxChatId = chatId;
    menu.querySelector('[data-ctx="pin"]').textContent = chat.pinned ? '取消置顶' : '置顶会话';
    menu.querySelector('[data-ctx="read"]').hidden = !chat.unread;
    menu.querySelector('[data-ctx="unread"]').hidden = !!chat.unread;
    menu.hidden = false;
    var rect = menu.getBoundingClientRect();
    var left = Math.min(x, window.innerWidth - rect.width - 8);
    var top = Math.min(y, window.innerHeight - rect.height - 8);
    menu.style.left = Math.max(8, left) + 'px';
    menu.style.top = Math.max(8, top) + 'px';
  }

  function closeCtxMenu() {
    var menu = $('ctxMenu');
    if (menu) menu.hidden = true;
    ctxChatId = null;
  }

  function ctxAction(kind) {
    var id = ctxChatId;
    closeCtxMenu();
    if (!id) return;
    var chat = state.chats.filter(function (c) { return c.id === id; })[0];
    if (!chat) return;
    if (kind === 'pin') {
      var next = !chat.pinned;
      api('/chats/' + encodeURIComponent(id) + '/pin', { method: 'POST', body: JSON.stringify({ pinned: next }) })
        .then(function () {
          chat.pinned = next;
          sortChats();
          renderChats();
          toast(next ? '已置顶会话' : '已取消置顶');
        })
        .catch(function (err) { toast(err.message, 'error'); });
      return;
    }
    if (kind === 'read' || kind === 'unread') {
      api('/chats/' + encodeURIComponent(id) + '/' + kind, { method: 'POST' })
        .then(function (r) {
          chat.unread = kind === 'read' ? 0 : ((r && r.unread) || 1);
          updateChatBadge();
          renderChats();
          toast(kind === 'read' ? '已标为已读' : '已标为未读');
        })
        .catch(function (err) { toast(err.message, 'error'); });
      return;
    }
    if (kind === 'del') {
      if (!window.confirm('删除会话「' + chat.title + '」？\n只会从你的列表里移除，对方那边不受影响。')) return;
      api('/chats/' + encodeURIComponent(id), { method: 'DELETE' })
        .then(function () {
          state.chats = state.chats.filter(function (c) { return c.id !== id; });
          if (state.activeChatId === id) {
            state.activeChatId = null;
            $('chatPane').hidden = true;
            $('emptyChat').hidden = false;
          }
          updateChatBadge();
          renderChats();
          toast('已删除会话');
        })
        .catch(function (err) { toast(err.message, 'error'); });
    }
  }

  function sortChats() {
    state.chats.sort(function (a, b) {
      if (!!a.pinned !== !!b.pinned) return a.pinned ? -1 : 1;
      return String(b.updatedAt).localeCompare(String(a.updatedAt));
    });
  }

  function renderChats() {
    var box = $('chatList');
    var keyword = $('sideSearch').value.trim().toLowerCase();
    var list = state.chats.filter(function (c) {
      if (state.listFilter === 'group' && c.type !== 'group') return false;
      return !keyword || c.title.toLowerCase().includes(keyword);
    });
    if (!list.length) {
      var emptyText = keyword
        ? '没有匹配的会话'
        : (state.listFilter === 'group' ? '还没有群聊，去「联系人」里发起一个' : '还没有会话，去「联系人」里发起一个吧');
      box.innerHTML = '<div class="list-title">' + emptyText + '</div>';
      return;
    }
    box.innerHTML = list.map(function (c) {
      var last = c.lastMessage;
      var peerId = c.type === 'direct' ? ((c.memberIds || []).filter(function (id) { return id !== state.me.id; })[0] || '') : '';
      /* 转账不进会话列表：预览用最近一条真正的会话消息；没有别的消息就留空 */
      var preview = last
        ? (last.preview
          ? ((last.senderId === state.me.id ? '我：' : (c.type === 'group' && last.senderName ? last.senderName + '：' : '')) + last.preview)
          : '')
        : '开始聊天';
      return '<div class="row' + (c.id === state.activeChatId ? ' is-active' : '') + (c.pinned ? ' is-pinned' : '') + '" data-chat="' + esc(c.id) + '">' +
        avatarHtml(c.avatar, c.title, 'div', peerId) +
        '<div class="row-main">' +
          '<div class="row-top"><span class="row-name">' + esc(c.title) + (c.type === 'group' ? ' (' + c.memberCount + ')' : '') + '</span>' +
          '<span class="row-time">' + (last ? formatTime(last.createdAt) : '') + '</span></div>' +
          '<button type="button" class="row-more" data-row-menu="' + esc(c.id) + '" title="更多操作">⋯</button>' +
          '<div class="row-bottom"><span class="row-preview">' + esc(preview) + '</span>' +
          (c.unread ? '<span class="badge">' + c.unread + '</span>' : '') + '</div>' +
        '</div>' +
        '</div>';
    }).join('');

    updateChatBadge();
  }

  /* -------------------------------------------------------- 未读角标与标题 */

  function unreadTotal() {
    return state.chats.reduce(function (sum, c) { return sum + (c.unread || 0); }, 0);
  }

  function updateChatBadge() {
    var badge = $('chatBadge');
    if (!badge) return;
    var total = unreadTotal();
    if (total > 0) {
      badge.hidden = false;
      badge.textContent = String(total);
    } else {
      badge.hidden = true;
    }
    updateTitle();
    markOfflineAvatars();
  }

  function updateTitle() {
    // 顶部标题 / 未读数都不要了。用一个零宽字符占位，
    // 这样浏览器标签不会因为标题为空而退化成显示网址。
    document.title = '\u200d';
  }

  function renderFriends() {
    var box = $('friendList');
    var kw = ($('sideSearch') && $('sideSearch').value ? $('sideSearch').value : '').trim().toLowerCase();
    var list = kw ? state.friends.filter(function (f) {
      return String(f.nickname || '').toLowerCase().indexOf(kw) >= 0 || String(f.username || '').toLowerCase().indexOf(kw) >= 0;
    }) : state.friends;
    if (!list.length) {
      box.innerHTML = '<div class="list-title">' + (kw ? '没有匹配的好友' : '还没有好友，点右上角 ＋ → 「添加好友」搜用户名') + '</div>';
    } else {
      box.innerHTML = list.map(function (f) {
        return '<div class="row" data-open-user="' + esc(f.id) + '">' +
          '<div class="row-avatar js-avatar-link" data-goto-moments="' + esc(f.id) + '" title="看 TA 的朋友圈">' + (f.avatar ? '<img src="' + esc(f.avatar) + '" alt="">' : esc(initials(f.nickname))) +
            (statusKey(f.id) !== 'offline' ? '<span class="online-dot"></span>' : '') + '</div>' +
          (function () {
        var chat = (state.chats || []).filter(function (c) {
          return c.type === 'direct' && (c.memberIds || []).indexOf(f.id) >= 0 && (c.memberIds || []).indexOf(state.me.id) >= 0;
        })[0];
        var last = chat ? chat.lastMessage : null;
        var time = last ? '<span class="row-time">' + formatTime(last.createdAt) + '</span>' : '';
        var prev = last ? ((last.senderId === state.me.id ? '我：' : '') + last.preview) : '';
        return '<div class="row-main">' +
          '<div class="row-top"><span class="row-name">' + esc(f.nickname) + '</span>' + time + '</div>' +
          (prev ? '<div class="row-bottom"><span class="row-preview">' + esc(prev) + '</span></div>' : '<div class="row-bottom"></div>') +
        '</div>';
      })() +
          '</div>';
      }).join('');
    }

    var section = $('requestSection');
    var badge = $('contactBadge');
    if (state.incoming.length) {
      section.hidden = false;
      badge.hidden = false;
      badge.textContent = String(state.incoming.length);
      $('requestList').innerHTML = state.incoming.map(function (r) {
        return '<div class="row">' +
          '<div class="row-avatar"' + (r.id ? ' data-uid="' + esc(r.id) + '"' : '') + '>' + (r.avatar ? '<img src="' + esc(r.avatar) + '" alt="">' : esc(initials(r.nickname))) + '</div>' +
          '<div class="row-main"><div class="row-top"><span class="row-name">' + esc(r.nickname) + '</span></div>' +
          '<div class="row-bottom"><span class="row-preview">请求加你为好友</span></div></div>' +
          '<div class="row-actions">' +
            '<button class="tiny-btn" data-accept="' + esc(r.requestId) + '">同意</button>' +
            '<button class="tiny-btn ghost" data-reject="' + esc(r.requestId) + '">拒绝</button>' +
          '</div></div>';
      }).join('');
    } else {
      section.hidden = true;
      badge.hidden = true;
    }
    markOfflineAvatars();
  }

  /* 通话记录（微信那样的一条气泡）：电话 / 摄像机小图标 + 文案 */
  var CALL_ICON_VOICE = '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M6.6 2.4c.5 0 1 .3 1.2.8l1.5 3.3c.2.5.1 1.1-.3 1.5l-1.3 1.3c1 2 2.6 3.6 4.6 4.6l1.3-1.3c.4-.4 1-.5 1.5-.3l3.3 1.5c.5.2.8.7.8 1.2v3.2c0 .8-.6 1.5-1.4 1.6-.6.1-1.2.1-1.9.1C9.7 19.9 4.1 14.3 3.3 6.6c-.1-.7-.1-1.3 0-1.9.1-.8.8-1.4 1.6-1.4h1.7z"/></svg>';
  var CALL_ICON_VIDEO = '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="2.2" y="5.6" width="13.2" height="12.8" rx="3.4"/><path d="M16.9 10.4l3.9-2.6c.5-.3 1.1 0 1.1.6v7.2c0 .6-.6.9-1.1.6l-3.9-2.6z"/></svg>';
  /** 通话记录文案：老记录的「通话结束 · 时长 0:15」统一成微信那样「通话时长 00:15」 */
  function desktopCallText(m) {
    var t = String(m.content || '');
    t = t.replace(/^视频通话结束\s*[·・]?\s*时长\s*/, '通话时长 ');
    t = t.replace(/^通话结束\s*[·・]?\s*时长\s*/, '通话时长 ');
    t = t.replace(/^视频通话时长\s*/, '通话时长 ');
    var mm = t.match(/^通话时长\s+(\d{1,2}):(\d{2})$/);
    if (mm) t = '通话时长 ' + ('0' + mm[1]).slice(-2) + ':' + mm[2];
    return t;
  }

  function renderMessages() {
    var box = $('messages');
    var list = state.messages[state.activeChatId] || [];
    var chat = state.chats.find(function (c) { return c.id === state.activeChatId; });
    var html = '';
    var lastDay = '';
    var prev = null;   // 上一条消息，用来判断是不是同一个人连着发（QQ 会把间距收紧）

    list.forEach(function (m) {
      var day = dayLabel(m.createdAt);
      if (day !== lastDay) {
        html += '<div class="day-divider"><span>' + esc(day) + '</span></div>';
        lastDay = day;
      }

      if (m.kind === 'system') {
        /* 微信的通话记录是一条气泡：自己打出去的在右边（绿），对方打来的在左边（白）。
           from 是服务端新加的；老记录没有 from，还是居中一行小灰字。 */
        var callFromId = (m.call && m.call.from) ? String(m.call.from) : '';
        if (callFromId) {
          var callMine = callFromId === state.me.id;
          var callUser = callMine ? state.me : (state.userCache[callFromId] || {});
          var callAvatar = callUser.avatar || '';
          var callName = callUser.nickname || callUser.name || (callMine ? '我' : '');
          var callTxt = desktopCallText(m);
          var callVideo = (m.call && String(m.call.media) === 'video') || String(m.content || '').indexOf('视频') >= 0;
          html += '<div class="msg ' + (callMine ? 'me' : 'other') + '" data-id="' + esc(m.id) + '">' +
            '<div class="msg-avatar js-avatar-link" data-goto-moments="' + esc(callFromId) + '" title="' + (callMine ? '我的名片' : '看 TA 的名片') + '">' +
              (callAvatar ? '<img src="' + esc(callAvatar) + '" alt="">' : esc(initials(callName))) +
            '</div>' +
            '<div class="msg-body">' +
              '<div class="bubble bubble-call">' +
                '<span class="call-ico">' + (callVideo ? CALL_ICON_VIDEO : CALL_ICON_VOICE) + '</span>' +
                '<span>' + esc(callTxt) + '</span>' +
              '</div>' +
              '<div class="msg-time">' + formatTime(m.createdAt) + '</div>' +
            '</div></div>';
          prev = null;
          return;
        }
        html += '<div class="msg msg-system" data-id="' + esc(m.id) + '">' +
          '<span class="system-pill">' + esc(m.content) + '</span></div>';
        prev = null;
        return;
      }

      var mine = m.senderId === state.me.id;
      var cont = !!(prev && prev.senderId === m.senderId &&
        (new Date(m.createdAt) - new Date(prev.createdAt)) < 3 * 60 * 1000);
      prev = m;
      var sender = state.userCache[m.senderId] || {};
      var name = mine ? '我' : (sender.nickname || '');
      var avatar = mine ? state.me.avatar : sender.avatar;
      var isLastMine = false;

      var content;
      if (m.recalled) {
        content = '<div class="bubble is-recalled">' + (mine ? '你撤回了一条消息' : (name || '对方') + '撤回了一条消息') + '</div>';
      } else if (m.kind === 'image') {
        content = '<div class="bubble"><img src="' + esc(m.content) + '" alt="图片" data-preview="' + esc(m.content) + '"></div>';
      } else if (m.kind === 'file') {
        content = fileMessageHtml(m.content);
      } else if (m.kind === 'audio') {
        content = voiceBubbleHtml(m);
      } else if (m.kind === 'gift') {
        content = giftBubbleHtml(m.content);
      } else if (m.kind === 'transfer') {
        content = transferBubbleHtml(m.content, state.me.id, m.senderId);
      } else if (m.kind === 'location') {
        content = locationCardHtml(m.content);
      } else {
        content = '<div class="bubble">' + esc(m.content) + '</div>';
      }

      var actions = '';
      if (mine && !m.recalled && m.kind !== 'system') {
        if ((Date.now() - new Date(m.createdAt).getTime()) < 120000) {
          actions += '<button data-recall="' + esc(m.id) + '">撤回</button>';
        }
      }

      html += '<div class="msg ' + (mine ? 'me' : 'other') + (m.pending ? ' pending' : '') + (cont ? ' is-cont' : '') + '" data-id="' + esc(m.id) + '">' +
        '<div class="msg-avatar js-avatar-link" data-goto-moments="' + esc(mine ? state.me.id : m.senderId) + '" title="' + (mine ? '我的名片' : '看 TA 的名片') + '">' + (avatar ? '<img src="' + esc(avatar) + '" alt="">' : esc(initials(name))) + '</div>' +
        '<div class="msg-body">' +
          ((chat && chat.type === 'group' && !mine) ? '<div class="msg-sender">' + esc(name) + '</div>' : '') +
          content +
          '<div class="msg-time">' + formatTime(m.createdAt) + '</div>' +
          (actions ? '<div class="msg-actions">' + actions + '</div>' : '') +
        '</div></div>';
      isLastMine = isLastMine || mine;
    });

    box.innerHTML = html || '<div class="day-divider"><span>还没有消息，打个招呼吧</span></div>';
    bindVoicePlayers();
    box.scrollTop = box.scrollHeight;
    markOfflineAvatars();
  }

  function updateTyping() {
    var hint = $('typingHint');
    var info = state.typing[state.activeChatId];
    if (info && Date.now() - info.at < 4000) {
      hint.hidden = false;
      hint.textContent = info.name + ' 正在输入…';
    } else {
      hint.hidden = true;
    }
  }

  function render() {
    renderChats();
    renderFriends();
    if (state.activeChatId) renderMessages();
    updateTyping();
    markOfflineAvatars();
    if (momentsInPip()) markOfflineAvatars(momentsPip.document.getElementById('momentsPane'));
  }

  /** 刷新会话头部的在线状态（对方改状态、上线/下线时也要跟着变） */
  function applyHeadStatus(userId) {
    var el = $('chatSubText');
    if (!el) return;
    var dot0 = $('chatStatusDot');
    if (!userId) { el.textContent = ''; if (dot0) dot0.hidden = true; return; }
    el.textContent = statusLabel(userId);
    var dot = $('chatStatusDot');
    if (dot) { dot.hidden = false; applyStatusDot(dot, statusKey(userId)); }
  }

  function refreshHeadStatus() {
    var chat = state.chats.filter(function (x) { return x.id === state.activeChatId; })[0];
    if (!chat || chat.type === 'group') return;
    var otherId = (chat.memberIds || []).filter(function (id) { return id !== state.me.id; })[0];
    if (otherId) applyHeadStatus(otherId);
  }

  /** 顶部蓝条：左边是当前账号，右边是当前会话对方（照设计图） */
  function renderTopbar() {
    var myAv = $('tbMyAv'), myName = $('tbMyName'), pAv = $('tbPeerAv'), pName = $('tbPeerName');
    if (!myAv || !myName || !state.me) return;
    myAv.innerHTML = state.me.avatar
      ? '<img src="' + esc(state.me.avatar) + '" alt="">'
      : esc(initials(state.me.nickname));
    myName.textContent = state.me.nickname;
    if (!pAv || !pName) return;
    var chat = state.chats.filter(function (c) { return c.id === state.activeChatId; })[0];
    if (chat) {
      pName.textContent = chat.title;
      pAv.innerHTML = chat.avatar ? '<img src="' + esc(chat.avatar) + '" alt="">' : esc(initials(chat.title));
    } else {
      pName.textContent = '未选择会话';
      pAv.textContent = '·';
    }
  }

  function renderMe() {
    $('meName').textContent = state.me.nickname;
    var img = $('meAvatar');
    var fb = $('meAvatarFallback');
    if (state.me.avatar) {
      img.src = state.me.avatar;
      img.hidden = false;
      fb.hidden = true;
    } else {
      img.hidden = true;
      fb.hidden = false;
      fb.textContent = initials(state.me.nickname);
    }
    applyMomentsHeader();
    $('meMenuHead').textContent = state.me.nickname + ' · @' + state.me.username;
    applyCover();
    applyChatBackground();
    renderTopbar();
  }

  /* ------------------------------------------------------------- 朋友圈 */

  var COVER_PRESETS = [
    'linear-gradient(150deg, #0b3d2c 0%, #0f6b45 45%, #0ad169 100%)',
    'linear-gradient(140deg, #1e3a8a 0%, #3b82f6 55%, #22d3ee 100%)',
    'linear-gradient(140deg, #4c1d95 0%, #a855f7 55%, #f472b6 100%)',
    'linear-gradient(140deg, #7c2d12 0%, #f97316 55%, #fbbf24 100%)',
    'linear-gradient(140deg, #0f172a 0%, #334155 55%, #64748b 100%)',
    'linear-gradient(140deg, #831843 0%, #e11d48 55%, #fb7185 100%)'
  ];

  function coverShorthand(value) {
    if (!value) return COVER_PRESETS[0];
    if (value.indexOf('preset:') === 0) {
      return COVER_PRESETS[Number(value.split(':')[1])] || COVER_PRESETS[0];
    }
    return 'url("' + value + '") center / cover no-repeat';
  }

  function applyCover() {
    var el = document.querySelector('.moments-cover');
    if (el) el.style.background = coverShorthand(state.me.momentCover);
  }

  function renderCoverPreview() {
    var draft = state.coverDraft || '';
    var box = $('coverPreview');
    if (!box) return;
    box.style.background = coverShorthand(draft);
    $('coverPreviewLabel').textContent = draft
      ? (draft.indexOf('preset:') === 0 ? '预设封面' : '自定义图片')
      : '默认封面';
    document.querySelectorAll('.cover-preset').forEach(function (b) {
      b.classList.toggle('is-active', draft === 'preset:' + b.getAttribute('data-preset'));
    });
  }

  function openCoverEditor() {
    state.coverDraft = state.me.momentCover || '';
    openModal('更换朋友圈背景图',
      '<div class="cover-preview" id="coverPreview"><span id="coverPreviewLabel"></span></div>' +
      '<div class="field"><span class="field-label">上传自己的图片（建议横图，8MB 以内）</span>' +
      '<input type="file" id="coverFile" accept="image/*"></div>' +
      '<div class="field"><span class="field-label">或者选一套预设</span>' +
      '<div class="cover-presets" id="coverPresets">' +
        COVER_PRESETS.map(function (g, i) {
          return '<button type="button" class="cover-preset" data-preset="' + i + '" style="background:' + g + '"></button>';
        }).join('') +
      '</div></div>',
      '<button class="btn-ghost" id="coverReset">恢复默认</button>' +
      '<button class="btn-primary" id="coverSave">保存背景图</button>');

    renderCoverPreview();

    $('coverPresets').addEventListener('click', function (e) {
      var btn = e.target.closest('[data-preset]');
      if (!btn) return;
      state.coverDraft = 'preset:' + btn.getAttribute('data-preset');
      renderCoverPreview();
    });

    $('coverReset').addEventListener('click', function () {
      state.coverDraft = '';
      renderCoverPreview();
    });

    $('coverFile').addEventListener('change', function (e) {
      var file = e.target.files && e.target.files[0];
      if (!file) return;
      if (file.size > 8 * 1024 * 1024) return toast('图片不能超过 8MB', 'error');
      var reader = new FileReader();
      reader.onload = function () {
        api('/upload', { method: 'POST', body: JSON.stringify({ dataUrl: String(reader.result) }) })
          .then(function (d) {
            state.coverDraft = d.url;
            renderCoverPreview();
            toast('图片已上传，点保存生效');
          })
          .catch(function (err) { toast(err.message, 'error'); });
      };
      reader.readAsDataURL(file);
      e.target.value = '';
    });

    $('coverSave').addEventListener('click', function () {
      var btn = this;
      btn.disabled = true;
      api('/me', { method: 'PATCH', body: JSON.stringify({ momentCover: state.coverDraft || '' }) })
        .then(function (data) {
          state.me = data.user;
          applyCover();
          closeModal();
          toast(state.me.momentCover ? '封面已更新' : '已恢复默认封面');
        })
        .catch(function (err) { toast(err.message, 'error'); })
        .then(function () { btn.disabled = false; });
    });
  }

  function setMomentBadge(count) {
    state.momentUnread = count || 0;
    var badge = $('momentBadge');
    if (state.momentUnread > 0) {
      badge.hidden = false;
      badge.textContent = String(state.momentUnread);
    } else {
      badge.hidden = true;
    }
  }

  function imageGrid(images) {
    if (!images || !images.length) return '';
    var cls = 'n' + Math.min(images.length, 9);
    return '<div class="moment-images ' + cls + '">' + images.map(function (src) {
      return '<img src="' + esc(src) + '" alt="图片" data-preview="' + esc(src) + '">';
    }).join('') + '</div>';
  }

  function bytesText(n) {
    var v = Number(n) || 0;
    if (v < 1024) return v + ' B';
    if (v < 1024 * 1024) return (v / 1024).toFixed(1) + ' KB';
    return (v / 1024 / 1024).toFixed(1) + ' MB';
  }

  function fileMessageHtml(content) {
    var info = {};
    try { info = JSON.parse(content); } catch (e) { info = { url: content, name: '文件' }; }
    return '<a class="bubble file-card" href="' + esc(info.url) + '" target="_blank" rel="noopener" download>' +
      '<span class="file-icon">📄</span><span>' +
        '<span class="file-name">' + esc(info.name || '文件') + '</span>' +
        '<span class="file-size">' + (info.bytes ? bytesText(info.bytes) : '点击下载') + '</span>' +
      '</span></a>';
  }

  /** 礼物消息：解析出图标 / 名字 / 价格，做成一张礼物卡（后台礼物管理里配的） */
  function giftInfo(content) {
    var g = {};
    try { g = JSON.parse(content) || {}; } catch (e) { g = { name: String(content || '礼物') }; }
    return { icon: g.icon || '🎁', name: g.name || '礼物', price: Number(g.price) || 0 };
  }

  function giftBubbleHtml(content) {
    var g = giftInfo(content);
    return '<div class="bubble gift-card">' +
      '<span class="gift-emoji">' + esc(g.icon) + '</span>' +
      '<span class="gift-text"><span class="gift-name">' + esc(g.name) + '</span>' +
      '<span class="gift-price">' + esc(g.price) + ' 金币</span></span>' +
    '</div>';
  }

  /* 转账卡片（电脑版）：橙色，和手机端一个样子 */
  /* 位置卡片（电脑版）：一张地图缩略图 + 地名（手机端扫的地图瓦片） */
  function locationInfo(content) {
    var o = {};
    try { o = JSON.parse(content) || {}; } catch (e) { o = {}; }
    return { lat: Number(o.lat) || 0, lng: Number(o.lng) || 0, name: o.name || '位置', addr: o.addr || '' };
  }
  function locTileUrl(lat, lng, z) {
    var n = Math.pow(2, z);
    var x = Math.floor((lng + 180) / 360 * n);
    var r = lat * Math.PI / 180;
    var y = Math.floor((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * n);
    return 'https://webrd01.is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x=' + (((x % n) + n) % n) + '&y=' + Math.max(0, Math.min(n - 1, y)) + '&z=' + z;
  }
  function locationCardHtml(content) {
    var o = locationInfo(content);
    return '<div class="bubble loc-card">' +
      '<div class="lc-thumb"><img src="' + esc(locTileUrl(o.lat, o.lng, 15)) + '" alt="" loading="lazy" decoding="async"></div>' +
      '<div class="lc-info"><div class="lc-t1">' + esc(o.name) + '</div><div class="lc-t2">' + esc(o.addr || '') + '</div></div>' +
      '</div>';
  }

  function transferInfo(content) {
    var t = {};
    try { t = JSON.parse(content) || {}; } catch (e) { t = {}; }
    return {
      id: t.id || '', amount: Number(t.amount) || 0, note: t.note || '', status: t.status || 'pending',
      fromId: t.fromId || '', toId: t.toId || '',
      createdAt: t.createdAt || '', expiresAt: t.expiresAt || 0,
      receivedAt: t.receivedAt || '', refundedAt: t.refundedAt || ''
    };
  }
  function transferBubbleHtml(content, meId, senderId) {
    var t = transferInfo(content);
    var mine = senderId === meId;
    var desc = mine ? '你发起了一笔转账' : '转账给你';
    var state = mine ? '待对方确认收款 · 24 小时未收款自动退回' : '24 小时未收款自动退回';
    var cls = '';
    if (t.status === 'received') { cls = ' is-done'; state = mine ? '对方已收款' : '已收款，钱已到你余额'; }
    else if (t.status === 'refunded') { cls = ' is-back'; state = mine ? '超过 24 小时未收款，已退回你的余额' : '已退回对方'; }
    return '<div class="bubble transfer-card' + cls + '" data-transfer="' + esc(t.id) + '" data-status="' + esc(t.status) +
      '" data-amount="' + t.amount.toFixed(2) + '" data-mine="' + (mine ? '1' : '0') + '">' +
      '<div class="tc-inner">' +
        '<span class="tc-icon">' +
          '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">' +
            '<path d="M4.2 8.6h13.2M14.6 5.4l3.2 3.2-3.2 3.2"/>' +
            '<path d="M19.8 15.4H6.6M9.4 12.2L6.2 15.4l3.2 3.2"/>' +
          '</svg>' +
        '</span>' +
        '<span class="tc-text">' +
          '<span class="tc-amount">¥' + t.amount.toFixed(2) + '</span>' +
          '<span class="tc-desc">' + esc(desc) + (t.note ? ' · ' + esc(t.note) : '') + '</span>' +
        '</span>' +
      '</div>' +
      '<div class="tc-foot"><span class="tc-label">转账</span><span class="tc-state">' + esc(state) + '</span>' +
        (!mine && t.status === 'pending' ? '<span class="tc-btn">收钱</span>' : '') +
      '</div></div>';
  }

  function findTransferMsg(id) {
    var list = state.messages[state.activeChatId] || [];
    for (var i = 0; i < list.length; i++) {
      var t = transferInfo(list[i].content);
      if (t.id === id) return { t: t, msg: list[i] };
    }
    return null;
  }
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
  /** 账单单号：1000050001 + 年月日时分秒 + 单号后半段 */
  function billNoDesktop(t) {
    var d = new Date(t.createdAt);
    var p = function (n) { return (n < 10 ? '0' : '') + n; };
    var stamp = isNaN(d.getTime()) ? '00000000000000'
      : ('' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds()));
    return '1000050001' + stamp + String(t.id || '').replace(/^tr_/, '').toUpperCase();
  }

  /** 电脑版转账详情：单独弹一页，排版比例和手机端那份稿一致 */
  function transferDetailModal(id) {
    var found = findTransferMsg(id);
    if (!found) { toast('这条转账的记录没找到'); return; }
    var t = found.t;
    var mine = found.msg.senderId === state.me.id;
    var chat = (state.chats || []).filter(function (c) { return c.id === state.activeChatId; })[0] || {};
    var peer = chat.title || '对方';
    var sender = state.userCache[found.msg.senderId] || {};
    var senderName = sender.nickname || peer;
    var title, hint, action = '', stateLine = '';
    if (t.status === 'pending') {
      if (mine) {
        title = '待' + peer + '收款';
        hint = leftText(t.expiresAt) + '内对方未收款，将退还给你。';
        action = '<button class="td-link" data-td-action="remind">提醒对方收款</button>';
        stateLine = '钱已经从你的余额扣下，等对方收款';
      } else {
        title = senderName + '向你转账';
        hint = leftText(t.expiresAt) + '内未收款，将退还对方。';
        action = '<button class="td-link" data-td-action="claim">立即收款</button>';
        stateLine = '钱已经从对方余额扣下，等你收款';
      }
    } else if (t.status === 'received') {
      title = mine ? '对方已收款' : '已收款';
      hint = '钱已存入' + (mine ? '对方' : '你的') + '零钱余额。';
      stateLine = t.receivedAt ? ('收款时间 ' + fmtTransferTime(t.receivedAt)) : '';
    } else {
      title = mine ? '已退回你的余额' : '已退回对方';
      hint = '超过 24 小时未收款，钱已原路退回。';
      stateLine = t.refundedAt ? ('退回时间 ' + fmtTransferTime(t.refundedAt)) : '';
    }
    var body =
      '<div class="td-page">' +
        '<div class="td-icon"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">' +
          '<path d="M7.4 5.6l4.6 5 4.6-5"/><path d="M12 10.2v8.2"/><path d="M8.2 12.6h7.6M8.2 15.4h7.6"/></svg></div>' +
        '<div class="td-title">' + esc(title) + '</div>' +
        '<div class="td-amount">¥' + t.amount.toFixed(2) + '</div>' +
        '<div class="td-hint"><span class="td-hint-text">' + esc(hint) + '</span>' + action + '</div>' +
        '<div class="td-rows">' +
          '<div class="td-row"><span class="td-k">转账时间</span><span class="td-v">' + esc(fmtTransferTime(t.createdAt)) + '</span></div>' +
          (t.note ? '<div class="td-row"><span class="td-k">转账说明</span><span class="td-v">' + esc(t.note) + '</span></div>' : '') +
          '<div class="td-row"><span class="td-k">转账单号</span><span class="td-v">' + esc(String(t.id || '').replace(/^tr_/, '').toUpperCase()) + '</span></div>' +
        '</div>' +
        (stateLine ? '<div class="td-state">' + esc(stateLine) + '</div>' : '') +
      '</div>';
    openModal('转账详情', body, '<button class="td-bill" data-td-action="bill">账单详情</button>');
    var root = $('modalCard');
    root.addEventListener('click', function (e) {
      var btn = e.target.closest('[data-td-action]');
      if (!btn) return;
      var act = btn.getAttribute('data-td-action');
      if (act === 'claim') { claimTransferDesktop(id); return; }
      if (act === 'remind') { toast('已提醒对方收款'); return; }
      if (act === 'bill') {
        var statusText = t.status === 'pending' ? (mine ? '等待对方确认收钱' : '等待你确认收钱') : (t.status === 'received' ? '已收款' : '已退回');
        var who = mine ? peer : senderName;
        var chatObj = (state.chats || []).filter(function (c) { return c.id === state.activeChatId; })[0] || {};
        var face = chatObj.avatar || '';
        var rows = [
          ['当前状态', statusText + (t.status === 'pending' ? '（' + leftText(t.expiresAt) + '后自动退回）' : '')],
          ['转账说明', t.note || '微信转账'],
          ['转账时间', fmtTransferTime(t.createdAt)],
          ['支付方式', t.method === 'card' ? '建设银行储蓄卡(2125)' : '零钱'],
          ['转账单号', billNoDesktop(t)]
        ];
        if (t.status === 'received') rows.push(['收款时间', fmtTransferTime(t.receivedAt)]);
        if (t.status === 'refunded') rows.push(['退回时间', fmtTransferTime(t.refundedAt)]);
        var billHtml =
          '<div class="bl-page">' +
            '<div class="bl-hero">' +
              '<div class="bl-avatar">' + (face ? '<img src="' + esc(face) + '" alt="">' : esc((who || '?').slice(0, 1))) + '</div>' +
              '<div class="bl-type">' + esc((mine ? '转账-转给' : '转账-来自') + who) + '</div>' +
              '<div class="bl-amount">' + (mine ? '-' : '+') + '¥' + t.amount.toFixed(2) + '</div>' +
            '</div>' +
            '<div class="bl-block">' +
              rows.map(function (r, idx) {
                var row = '<div class="bl-row"><span class="bl-k">' + esc(r[0]) + '</span><span class="bl-v">' + esc(r[1]) + '</span></div>';
                // 「立即收款 / 提醒对方收款」紧跟在「当前状态」那行下面（和参考图一致）
                if (idx === 0 && t.status === 'pending') {
                  row += '<div class="bl-row is-plain"><button class="bl-link" data-td-action="' + (mine ? 'remind' : 'claim') + '">' + (mine ? '提醒对方收款' : '立即收款') + '</button></div>';
                }
                return row;
              }).join('') +
            '</div>' +
            '<div class="bl-block is-service">' +
              '<div class="bl-head">账单服务</div>' +
              '<button class="bl-srow" data-bill-locate="1"><span class="bl-sico">💬</span><span class="bl-sname">定位到聊天位置</span><span class="me-arrow">›</span></button>' +
            '</div>' +
          '</div>';
        openModal('账单', billHtml, '');
        var locate = $('modalCard').querySelector('[data-bill-locate]');
        if (locate) locate.addEventListener('click', function () {
          closeModal();
          var box = document.querySelector('.bubble.transfer-card[data-transfer="' + id + '"]');
          if (box && box.scrollIntoView) box.scrollIntoView({ block: 'center', behavior: 'smooth' });
        });
      }
    });
  }

  function claimTransferDesktop(id) {
    api('/transfers/' + encodeURIComponent(id) + '/claim', { method: 'POST', body: JSON.stringify({}) })
      .then(function (d) {
        var amt = d && d.transfer ? Number(d.transfer.amount) || 0 : 0;
        toast('已收款 ¥' + amt.toFixed(2));
        closeModal();
        if (state.activeChatId) renderMessages();
      })
      .catch(function (e) { toast(e.message || '收款失败'); });
  }

  /** 电脑版点转账卡片：打开转账详情页；点白按钮「收钱」直接收 */
  function onTransferCardClick(card) {
    var id = card.getAttribute('data-transfer');
    transferDetailModal(id);
  }

  var EMOJIS = ['😀', '😁', '😂', '🤣', '😊', '😍', '😘', '😎', '🤔', '😅',
    '😖', '😳', '😭', '😚', '🤐', '😴', '😢', '😅', '😡',
    '😛', '😲', '😔', '😰', '😫', '🤢', '🤭', '🙄', '😤',
    '🤤', '😪', '😱', '🫡', '💪', '🤬', '🤔', '🤫', '😵',
    '😩', '😞', '💀', '🔨', '👋', '🤧', '👏', '😏', '🥱',
    '😒', '🥺', '🔪', '🍉', '🍺', '🏀', '🏓', '☕', '🍚',
    '🐷', '🌹', '🥀', '❤️', '💔', '🎂', '⚡', '💣', '🗡️',
    '⚽', '🐞', '💩', '🌙', '☀️', '🎁', '🤗', '👍', '👎',
    '🤝', '✌️', '🙏', '😉', '👊', '👌', '🕺', '🥶', '🌀',
    '🙇', '🏃', '🤩', '🎉', '🔥', '⭐', '🌈', '🎵', '🧧',
    '☁️', '🌧️', '❄️', '🐱', '🐶', '🐼', '🐰', '🐵', '🐯',
    '🐟', '🍎', '🍓'];

  /** 按 id 找到昵称和头像，用来渲染某个人的朋友圈 */
  function userInfoById(id) {
    if (!id) return null;
    if (state.me && id === state.me.id) return { nickname: state.me.nickname, avatar: state.me.avatar };
    var f = (state.friends || []).filter(function (x) { return x.id === id; })[0];
    if (f) return { nickname: f.nickname, avatar: f.avatar };
    var c = (state.chats || []).filter(function (x) {
      return x.type === 'direct' && (x.memberIds || []).indexOf(id) !== -1;
    })[0];
    if (c) return { nickname: c.title, avatar: c.avatar };
    var mm = (state.moments || []).filter(function (x) { return x.authorId === id; })[0];
    if (mm && mm.author) return { nickname: mm.author.nickname, avatar: mm.author.avatar };
    var cached = state.userCache && state.userCache[id];
    if (cached && cached.nickname) return { nickname: cached.nickname, avatar: cached.avatar || '' };
    return null;
  }

  /** 打开某个人（或自己）的朋友圈 */
  function openUserMoments(userId, nickname, avatar) {
    if (!userId) return;
    var info = userInfoById(userId) || {};
    state.momentUser = userId;
    state.momentUserInfo = { nickname: nickname || info.nickname || 'TA', avatar: avatar || info.avatar || '' };
    state.commenting = null;
    if ($('modalMask') && !$('modalMask').hidden) closeModal();
    if (state.panel === 'moments' || momentsInPip()) {
      applyMomentsHeader();
      loadMoments(false, userId).catch(function (err) { toast(err.message, 'error'); });
    } else {
      switchPanel('moments');
    }
  }

  function closeUserMoments() {
    state.momentUser = null;
    state.momentUserInfo = null;
    if (momentsInPip()) {
      applyMomentsHeader();
      loadMoments(true).catch(function () { });
      return;
    }
    switchPanel('moments');
  }

  /** 头像点击统一入口：点到头像先弹微信式名片（名片里再进朋友圈） */
  function momentsLinkFrom(e) {
    var el = e.target && e.target.closest ? e.target.closest('[data-goto-moments]') : null;
    if (!el) return false;
    var id = el.getAttribute('data-goto-moments');
    if (!id) return false;
    var info = userInfoById(id) || {};
    var named = el.getAttribute('data-moment-name') || '';
    var faced = el.getAttribute('data-moment-avatar') || '';
    openProfileCard(id, named || info.nickname, faced || info.avatar);
    return true;
  }

  /** 微信式名片：头像 / 昵称 / 微信号 / 地区 / 个性签名 / 朋友圈九宫格 / 发消息·音视频通话 */
  function cardRow(label, value) {
    if (!value) return '';
    return '<div class="wxcard-row"><span class="wxcard-label">' + esc(label) + '</span><span class="wxcard-value">' + esc(value) + '</span></div>';
  }

  function renderProfileCard(u, photos) {
    var mine = state.me && u.id === state.me.id;
    var isFriend = u.relation === 'friend' || mine;
    var face = u.avatar ? '<img src="' + esc(u.avatar) + '" alt="">' : esc(initials(u.nickname));
    var cardPhotos = (photos || []).slice(0, 5);
    var photoHtml = cardPhotos.map(function (p) {
      return '<span class="wxcard-photo" data-card-photo="' + esc(p) + '"><img src="' + esc(p) + '" alt=""></span>';
    }).join('');
    var body =
      '<div class="wxcard">' +
        '<div class="wxcard-head">' +
          '<div class="wxcard-face" data-uid="' + esc(u.id) + '">' + face + '</div>' +
          '<div class="wxcard-info">' +
            '<div class="wxcard-name">' + esc(u.nickname) + genderIconHtml(u.gender) + (mine ? ' <i class="wxcard-me">我</i>' : '') + '</div>' +
            (u.username ? '<div class="wxcard-sub">微信号：' + esc(u.username) + '</div>' : '') +
            (u.region ? '<div class="wxcard-sub">地区：' + esc(u.region) + '</div>' : '') +
            (u.online !== undefined && !mine ? '<div class="wxcard-sub">' + (u.online ? '在线' : '离线') + '</div>' : '') +
          '</div>' +
        '</div>' +
        (u.bio ? '<div class="wxcard-sign">' + esc(u.bio) + '</div>' : '') +
        '<div class="wxcard-rows">' +
          '<div class="wxcard-row"><span class="wxcard-label">微信号</span><span class="wxcard-value">' + esc(u.username || '-') + '</span></div>' +
          (u.region ? '<div class="wxcard-row"><span class="wxcard-label">地区</span><span class="wxcard-value">' + esc(u.region) + '</span></div>' : '') +
          (u.phone ? '<div class="wxcard-row"><span class="wxcard-label">电话</span><span class="wxcard-value">' + esc(u.phone) + '</span></div>' : '') +
          '<div class="wxcard-row wxcard-row-link" data-card-moments="' + esc(u.id) + '"><span class="wxcard-label">朋友圈</span><span class="wxcard-value">' +
            '<span class="wxcard-more">' + (u.momentCount ? u.momentCount + ' 张照片' : (photoHtml ? '看照片' : '还没发过')) + ' ›</span>' +
          '</span></div>' +
        '</div>' +
        // 名片里「朋友圈」下面：小图一行最多放 5 张
        (photoHtml ? '<div class="wxcard-photos-two">' +
          cardPhotos.map(function (p) { return '<span class="wxcard-photo2" data-card-photo="' + esc(p) + '"><img src="' + esc(p) + '" alt=""></span>'; }).join('') + '</div>' : '') +
        (mine ? '' : '<div class="wxcard-rows">' +
          '<div class="wxcard-row"><span class="wxcard-label">共同群聊</span><span class="wxcard-value">' + (u.mutualGroups || 0) + ' 个</span></div>' +
          '<div class="wxcard-row"><span class="wxcard-label">添加时间</span><span class="wxcard-value">' + esc(String(u.createdAt || '').slice(0, 10)) + '</span></div>' +
        '</div>') +

      '</div>';
    // 名片底部：图标在上、文字在下的三个按钮（和参考图一致）
    var icoMsg = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">' +
      '<path d="M12 3.4c5 0 9.1 3.5 9.1 7.7 0 4.3-4.1 7.7-9.1 7.7-1 0-2-.1-2.9-.4l-4.4 2 1.2-3.7C3.6 15.3 2.9 13.3 2.9 11.1c0-4.2 4.1-7.7 9.1-7.7z"/></svg>';
    var icoVoice = '<svg viewBox="0 0 24 24" fill="currentColor">' +
      '<path d="M6.62 10.79c1.44 2.83 3.76 5.14 6.59 6.59l2.2-2.2c.27-.27.67-.36 1.02-.24 1.12.37 2.33.57 3.57.57.55 0 1 .45 1 1V20c0 .55-.45 1-1 1-9.39 0-17-7.61-17-17 0-.55.45-1 1-1h3.5c.55 0 1 .45 1 1 0 1.25.2 2.45.57 3.57.11.35.03.74-.25 1.02l-2.2 2.2z"/></svg>';
    var icoVideo = '<svg viewBox="0 0 24 24" fill="currentColor">' +
      '<path d="M17 10.5V7c0-.55-.45-1-1-1H4c-.55 0-1 .45-1 1v10c0 .55.45 1 1 1h12c.55 0 1-.45 1-1v-3.5l4 4v-11l-4 4z"/></svg>';
    var foot = '<div class="card-actions">' +
      '<button type="button" class="card-action" id="cardChat">' + icoMsg + '<span>发消息</span></button>' +
      (mine ? '' :
        '<button type="button" class="card-action" id="cardVoice">' + icoVoice + '<span>语音聊天</span></button>' +
        '<button type="button" class="card-action" id="cardVideo">' + icoVideo + '<span>视频聊天</span></button>') +
      '</div>';
    openModal('', body, foot);
    markOfflineAvatars();
    var close = function () { closeModal(); };
    if ($('cardChat')) $('cardChat').onclick = function () { close(); openDirectWith(u.id); };
    if ($('cardMsgSelf')) $('cardMsgSelf').onclick = function () { close(); openDirectWith(u.id); };
    if ($('cardVoice')) $('cardVoice').onclick = function () { close(); startCall(u.id, u.nickname, u.avatar, 'audio'); };
    if ($('cardVideo')) $('cardVideo').onclick = function () { close(); startCall(u.id, u.nickname, u.avatar, 'video'); };
    if ($('cardEditMe')) $('cardEditMe').onclick = function () { close(); modalProfile(); };
    if ($('cardMyMoments')) $('cardMyMoments').onclick = function () { close(); openUserMoments(u.id, u.nickname, u.avatar); };
    var sec = document.querySelector('[data-card-moments]');
    if (sec) sec.onclick = function () { close(); openUserMoments(u.id, u.nickname, u.avatar); };
    // 名片里的朋友圈缩略图：点一下直接预览大图（左右可以翻）
    var cardPhotos = Array.prototype.map.call(document.querySelectorAll('[data-card-photo]'), function (x) { return x.getAttribute('data-card-photo'); });
    Array.prototype.forEach.call(document.querySelectorAll('[data-card-photo]'), function (ph, idx) {
      ph.onclick = function (ev) {
        if (ev) { ev.stopPropagation(); ev.preventDefault(); }
        openPhotoView(cardPhotos, idx);
      };
    });
  }

  /* ---------------- 大图预览（名片缩略图 / 朋友圈图片都能用） ---------------- */
  /* 记住最近一次点击的头像位置：名片就贴着它弹出来 */
  var lastAvatarRect = null;
  document.addEventListener('pointerdown', function (e) {
    var t = e.target && e.target.closest ? e.target.closest('[data-goto-moments], .row-avatar, .msg-avatar, .moment-avatar, #meAvatarBtn, #chatAvatar') : null;
    if (t) { var r = t.getBoundingClientRect(); lastAvatarRect = { left: r.left, top: r.top, right: r.right, bottom: r.bottom, w: r.width, h: r.height }; }
  }, true);

  var pvList = [], pvIdx = 0;
  function pvEl() {
    // 朋友圈在画中画窗口里时，大图也开在画中画窗口里
    var doc = activeDoc();
    var el = doc.getElementById('photoView');
    if (el) return el;
    el = doc.createElement('div');
    el.id = 'photoView';
    el.className = 'photo-view';
    el.innerHTML = '<button class="pv-close" id="pvClose" title="关闭">✕</button>' +
      '<button class="pv-nav pv-prev" id="pvPrev" title="上一张">‹</button>' +
      '<img id="pvImg" alt="">' +
      '<button class="pv-nav pv-next" id="pvNext" title="下一张">›</button>' +
      '<div class="pv-count" id="pvCount"></div>';
    doc.body.appendChild(el);
    doc.addEventListener('keydown', function (e) {
      if (!el.classList.contains('is-open')) return;
      if (e.key === 'Escape') closePhotoView();
      else if (e.key === 'ArrowLeft') pvGo(-1);
      else if (e.key === 'ArrowRight') pvGo(1);
    });
    el.addEventListener('click', function (ev) {
      if (ev.target === el || ev.target.id === 'pvClose') closePhotoView();
    });
    el.querySelector('#pvPrev').addEventListener('click', function (ev) { ev.stopPropagation(); pvGo(-1); });
    el.querySelector('#pvNext').addEventListener('click', function (ev) { ev.stopPropagation(); pvGo(1); });
    el.querySelector('#pvImg').addEventListener('click', function (ev) { ev.stopPropagation(); closePhotoView(); });
    return el;
  }
  function pvGo(step) {
    if (pvList.length < 2) return;
    pvIdx = (pvIdx + step + pvList.length) % pvList.length;
    pvRender();
    pvRenderInWindow();
  }
  function pvRender() {
    var el = pvEl();
    el.querySelector('#pvImg').src = pvList[pvIdx];
    el.querySelector('#pvCount').textContent = pvList.length > 1 ? ((pvIdx + 1) + ' / ' + pvList.length) : '';
    el.querySelector('#pvPrev').style.display = pvList.length > 1 ? 'block' : 'none';
    el.querySelector('#pvNext').style.display = pvList.length > 1 ? 'block' : 'none';
  }
  var pvWin = null;
  function openPhotoView(list, idx) {
    pvList = (list || []).filter(Boolean);
    if (!pvList.length) return;
    pvIdx = Math.max(0, Math.min(idx || 0, pvList.length - 1));
    // 优先开一个"独立的图片窗口"（不是网页式预览）
    var w = null;
    /* 统一走软件内部的全屏大图查看，绝不开浏览器窗口 */
    pvRender();
    pvEl().classList.add('is-open');
  }
  function pvRenderInWindow() {
    /* 已改为软件内部查看，这里不再需要独立浏览器窗口 */
  }
  function closePhotoView() {
    var el = $('photoView');
    if (el) el.classList.remove('is-open');
  }

  function openProfileCard(userId, nickname, avatar) {
    if (!userId) return;
    // 朋友圈列表里的图片也能点开预览
    setTimeout(function () {
      var imgs = document.querySelectorAll('#momentList .moment-images img');
      Array.prototype.forEach.call(imgs, function (im) {
        if (im.dataset.pvBound) return;
        im.dataset.pvBound = '1';
        im.addEventListener('click', function (ev) {
          ev.stopPropagation();
          var box = im.closest('.moment-images');
          var all = box ? Array.prototype.map.call(box.querySelectorAll('img'), function (x) { return x.src; }) : [im.src];
          openPhotoView(all, all.indexOf(im.src));
        });
      });
    }, 0);
    var info = userInfoById(userId) || {};
    var cached = state.userCache && state.userCache[userId];
    renderProfileCard({
      id: userId, nickname: nickname || info.nickname || (cached && cached.nickname) || 'TA',
      avatar: avatar || info.avatar || (cached && cached.avatar) || '',
      username: (cached && cached.username) || '', bio: (cached && cached.bio) || '',
      relation: userId === (state.me && state.me.id) ? 'self' : 'friend', momentCount: 0
    }, []);
    api('/users/' + encodeURIComponent(userId)).then(function (d) {
      var u = d.user || {};
      state.userCache[userId] = u;
      return api('/moments?userId=' + encodeURIComponent(userId) + '&limit=8').then(function (m) {
        var photos = [];
        (m.moments || []).forEach(function (mo) { (mo.images || []).forEach(function (img) { if (photos.length < 5) photos.push(img); }); });
        renderProfileCard(u, photos);
      }).catch(function () { renderProfileCard(u, []); });
    }).catch(function (err) { toast(err.message, 'error'); });
  }

  /** 朋友圈页头：区分「大家的」和「某个人的」 */
  /* 朋友圈右上角相机按钮：点开是「发表动态 / 更换背景图」两个选项 */
  function openFabMenu() {
    var m = $('fabMenu');
    if (!m) return;
    m.hidden = false;
    if ($('publishBtn')) $('publishBtn').classList.add('is-open');
  }

  function closeFabMenu() {
    var m = $('fabMenu');
    if (!m || m.hidden) return;
    m.hidden = true;
    if ($('publishBtn')) $('publishBtn').classList.remove('is-open');
  }

  function toggleFabMenu() {
    var m = $('fabMenu');
    if (!m) return;
    if (m.hidden) openFabMenu(); else closeFabMenu();
  }

  /* ---------------- 朋友圈画中画浮窗（点左边栏的朋友圈图标弹出） ---------------- */
  function pipSupported() {
    return !!(window.documentPictureInPicture && documentPictureInPicture.requestWindow);
  }

  function momentsInPip() {
    if (!momentsPip || momentsPip.closed) return false;
    try { return !!momentsPip.document.getElementById('momentsPane'); } catch (e) { return false; }
  }

  function closeMomentsPip() {
    if (momentsPip && !momentsPip.closed) { try { momentsPip.close(); } catch (e) { /* 忽略 */ } }
  }

  /** 打开（或再点一次关掉）朋友圈画中画浮窗；返回 true 表示这次点击由浮窗处理 */
  function openMomentsPip() {
    if (!pipSupported()) return false;
    // 手机版不用画中画：直接在主界面切换
    if (window.innerWidth <= 640) return false;
    if (momentsInPip()) { closeMomentsPip(); return true; }
    var pane = $('momentsPane');
    if (!pane) return false;

    documentPictureInPicture.requestWindow({ width: 420, height: 680 }).then(function (win) {
      momentsPip = win;

      // 样式 / 主题搬进浮窗
      Array.prototype.forEach.call(document.querySelectorAll('link[rel="stylesheet"], style'), function (node) {
        win.document.head.appendChild(node.cloneNode(true));
      });
      var theme = document.documentElement.getAttribute('data-theme') || 'light';
      win.document.documentElement.setAttribute('data-theme', theme);
      try { win.document.documentElement.style.colorScheme = theme; } catch (e) { }
      // 浮窗标题留一个零宽字符：这样浏览器标题栏不会因为标题为空而显示网址
      win.document.title = '\u200d';
      var extra = win.document.createElement('style');
      extra.textContent =
        'html,body{margin:0;padding:0;height:100%;overflow:hidden;background:var(--wx-bg-2,#fff);}' +
        'body{display:flex;flex-direction:column;}' +
        '#momentsPane{display:flex!important;flex:1 1 auto!important;min-height:0!important;}' +
        '.moments-body{padding-bottom:32px!important;}';
      win.document.head.appendChild(extra);

      // 朋友圈整块搬进浮窗
      momentsHome = { parent: pane.parentNode, next: pane.nextSibling };
      pane.hidden = false;
      win.document.body.appendChild(pane);
      applyMomentsHeader();
      loadMoments(true).catch(function () { });
      // 左边栏把「朋友圈」点亮（主窗口内容不动）
      document.querySelectorAll('.side-tab').forEach(function (t) {
        t.classList.toggle('is-active', t.getAttribute('data-panel') === 'moments');
      });

      // 浮窗关掉：把朋友圈和各种弹层搬回主窗口
      win.addEventListener('pagehide', function () {
        try {
          if (momentsHome && momentsHome.parent) momentsHome.parent.insertBefore(pane, momentsHome.next || null);
          pane.hidden = true;
          var mask = win.document.getElementById('modalMask');
          if (mask) { mask.hidden = true; document.body.appendChild(mask); }
          var pv = win.document.getElementById('photoView');
          if (pv) { pv.classList.remove('is-open'); document.body.appendChild(pv); }
          var fm = win.document.getElementById('fabMenu');
          if (fm) fm.hidden = true;
        } catch (e) { /* 忽略 */ }
        momentsPip = null;
        momentsHome = null;
        document.querySelectorAll('.side-tab').forEach(function (t) {
          t.classList.toggle('is-active', t.getAttribute('data-panel') === state.panel);
        });
      });

      // Esc：先关大图/弹窗，都没有才关浮窗
      win.addEventListener('keydown', function (e) {
        if (e.key !== 'Escape') return;
        var pv = win.document.getElementById('photoView');
        if (pv && pv.classList.contains('is-open')) return;
        var mask = win.document.getElementById('modalMask');
        if (mask && !mask.hidden) return;
        win.close();
      });
    }).catch(function (err) {
      toast('画中画打开失败：' + ((err && err.message) || '浏览器不支持'), 'error');
      switchPanel('moments');
    });
    return true;
  }

  function applyMomentsHeader() {
    var uid = state.momentUser;
    var mine = !uid;
    var self = !!uid && state.me && uid === state.me.id;
    var info = state.momentUserInfo || {};
    var back = $('momentsBack');
    var tag = $('momentsTag');
    var cover = $('coverBtn');
    var fab = $('publishBtn');
    if (back) back.hidden = mine;
    if (cover) cover.hidden = !mine && !self;
    if (fab) fab.hidden = !mine && !self;
    if (tag) {
      tag.hidden = mine;
      if (!mine) tag.textContent = self ? '我的朋友圈' : '的朋友圈';
    }
    if (mine) {
      $('momentsName').textContent = state.me ? state.me.nickname : '—';
      $('momentsAvatar').innerHTML = state.me && state.me.avatar
        ? '<img src="' + esc(state.me.avatar) + '" alt="">'
        : esc(initials(state.me ? state.me.nickname : '?'));
    } else {
      $('momentsName').textContent = info.nickname || 'TA';
      $('momentsAvatar').innerHTML = info.avatar
        ? '<img src="' + esc(info.avatar) + '" alt="">'
        : esc(initials(info.nickname || '?'));
    }
    $('momentsEmpty').textContent = mine
      ? '还没有动态。发一条，或者加几个好友看看他们在发什么。'
      : '这里还看不到动态：TA 没发过，或者你们还不是好友。';
  }

  /** 朋友圈左侧日期栏：今天 / 昨天 / N天前 / 月日 / 年月日 + 发布时间 */
  function momentDateParts(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return { day: '', clock: '', full: '' };
    var now = new Date();
    var p2 = function (n) { return (n < 10 ? '0' : '') + n; };
    var same = function (a, b) {
      return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
    };
    var yest = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
    var day;
    if (same(d, now)) day = '今天';
    else if (same(d, yest)) day = '昨天';
    else {
      var today0 = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
      var d0 = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
      var days = Math.round((today0 - d0) / 86400000);
      if (days > 1 && days < 7) day = days + '天前';
      else if (d.getFullYear() === now.getFullYear()) day = (d.getMonth() + 1) + '月' + d.getDate() + '日';
      else day = d.getFullYear() + '年' + (d.getMonth() + 1) + '月' + d.getDate() + '日';
    }
    var clock = p2(d.getHours()) + ':' + p2(d.getMinutes());
    var full = d.getFullYear() + '年' + (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + clock;
    return { day: day, clock: clock, full: full };
  }

  function renderMoments() {
    var box = $('momentList');
    var list = state.moments;
    $('momentsEmpty').hidden = list.length > 0;
    box.innerHTML = list.map(function (m) {
      var likes = m.likes || [];
      var comments = m.comments || [];
      var social = '';
      if (likes.length || comments.length) {
        social = '<div class="moment-social' + (likes.length ? '' : ' no-likes') + '">' +
          (likes.length
            ? '<div class="moment-likes"><span class="heart">♥</span>' +
              likes.map(function (l) { return esc(l.nickname); }).join('，') + '</div>'
            : '') +
          (comments.length
            ? '<div class="moment-comments">' + comments.map(function (c) {
              return '<div class="moment-comment"><b>' + esc(c.nickname) + '</b>' +
                (c.replyToName ? ' 回复 <b>' + esc(c.replyToName) + '</b>' : '') +
                '：' + esc(c.content) + '</div>';
            }).join('') + '</div>'
            : '') +
          '</div>';
      }

      var commentBar = state.commenting === m.id
        ? '<div class="comment-bar">' +
            '<input data-comment-input="' + esc(m.id) + '" placeholder="评论…">' +
            '<button data-comment-send="' + esc(m.id) + '">发送</button></div>'
        : '';

      var dp = momentDateParts(m.createdAt);
      return '<div class="moment" data-moment="' + esc(m.id) + '">' +
        '<div class="moment-date" title="' + esc(dp.full) + '">' +
          '<span class="md-day">' + esc(dp.day) + '</span>' +
        '</div>' +
        '<div class="moment-avatar js-avatar-link" data-goto-moments="' + esc(m.authorId) + '" title="看 TA 的朋友圈">' +
          (m.author && m.author.avatar
            ? '<img src="' + esc(m.author.avatar) + '" alt="">'
            : esc(initials(m.author ? m.author.nickname : '?'))) +
        '</div>' +
        '<div class="moment-main">' +
          '<div class="moment-name js-avatar-link" data-goto-moments="' + esc(m.authorId) + '" title="看 TA 的朋友圈">' +
            esc(m.author ? m.author.nickname : '未知') + '</div>' +
          (m.content ? '<p class="moment-text">' + esc(m.content) + '</p>' : '') +
          imageGrid(m.images) +
          '<div class="moment-foot">' +
            '<span class="moment-ops">' +
              '<button data-like="' + esc(m.id) + '" class="op-like' + (m.likedByMe ? ' is-liked' : '') + '" title="赞" aria-label="赞">' +
                (m.likedByMe
                  ? '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 20.6l-1.3-1.2C5.9 15.2 3 12.6 3 9.3 3 6.6 5.1 4.5 7.7 4.5c1.5 0 3 .7 4.3 2.1 1.3-1.4 2.8-2.1 4.3-2.1 2.6 0 4.7 2.1 4.7 4.8 0 3.3-2.9 5.9-7.7 10.1L12 20.6z"/></svg>'
                  : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 20.2l-1.2-1.1C6.1 14.9 3.3 12.4 3.3 9.3c0-2.5 2-4.5 4.5-4.5 1.4 0 2.8.7 4.2 2.1 1.4-1.4 2.8-2.1 4.2-2.1 2.5 0 4.5 2 4.5 4.5 0 3.1-2.8 5.6-7.5 9.8L12 20.2z"/></svg>') +
              '</button>' +
              '<button data-comment="' + esc(m.id) + '" class="op-comment" title="评论" aria-label="评论">' +
                '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20.4 12.2c0 3.8-3.8 6.9-8.4 6.9-.9 0-1.8-.1-2.6-.3l-4.1 1.9 1.2-3.5C5 15.8 3.6 14.1 3.6 12.2c0-3.8 3.8-6.9 8.4-6.9s8.4 3.1 8.4 6.9z"/></svg>' +
              '</button>' +
              (m.mine
                ? '<button data-del-moment="' + esc(m.id) + '" class="op-del" title="删除" aria-label="删除">' +
                  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4.8 6.9h14.4"/><path d="M9.4 6.9V4.8h5.2v2.1"/><path d="M6.6 6.9l.9 12.1h9l.9-12.1"/><path d="M10.4 10.6v5M13.6 10.6v5"/></svg>' +
                  '</button>'
                : '') +
            '</span>' +
          '</div>' +
          social + commentBar +
        '</div></div>';
    }).join('');

    if (state.commenting) {
      var input = box.querySelector('[data-comment-input]');
      if (input) input.focus();
    }
    markOfflineAvatars(box);
  }

  function loadMoments(markSeen, userId) {
    var uid = userId === undefined ? state.momentUser : userId;
    var url = '/moments?limit=30' + (uid ? '&userId=' + encodeURIComponent(uid) : '');
    return api(url).then(function (data) {
      state.moments = data.moments || [];
      if (uid && data.target) {
        var cur = state.momentUserInfo || {};
        if (!cur.nickname || cur.nickname === 'TA') {
          state.momentUserInfo = { nickname: data.target.nickname, avatar: data.target.avatar };
        }
      }
      if (!uid) setMomentBadge(markSeen ? 0 : data.unread);
      renderMoments();
      applyMomentsHeader();
      if (markSeen && !uid) return api('/moments/seen', { method: 'POST' }).catch(function () {});
      return null;
    });
  }

  function patchMoment(updated) {
    var idx = state.moments.findIndex(function (m) { return m.id === updated.id; });
    if (idx === -1) state.moments.unshift(updated);
    else state.moments[idx] = updated;
    renderMoments();
  }

  function toggleLike(momentId) {
    api('/moments/' + encodeURIComponent(momentId) + '/like', { method: 'POST' })
      .then(function (data) { patchMoment(data.moment); })
      .catch(function (err) { toast(err.message, 'error'); });
  }

  function submitComment(momentId) {
    var input = document.querySelector('[data-comment-input="' + momentId + '"]');
    if (!input) return;
    var content = input.value.trim();
    if (!content) return;
    api('/moments/' + encodeURIComponent(momentId) + '/comments', {
      method: 'POST', body: JSON.stringify({ content: content })
    }).then(function (data) {
      state.commenting = null;
      patchMoment(data.moment);
    }).catch(function (err) { toast(err.message, 'error'); });
  }

  function deleteMoment(momentId) {
    if (!window.confirm('确定删除这条动态吗？')) return;
    api('/moments/' + encodeURIComponent(momentId), { method: 'DELETE' })
      .then(function () {
        state.moments = state.moments.filter(function (m) { return m.id !== momentId; });
        renderMoments();
        toast('已删除');
      })
      .catch(function (err) { toast(err.message, 'error'); });
  }

  function renderComposeImages() {
    var box = $('composeImages');
    if (!box) return;
    box.innerHTML = state.composeImages.map(function (src, i) {
      return '<div class="compose-thumb"><img src="' + esc(src) + '" alt="">' +
        '<button data-remove-img="' + i + '">✕</button></div>';
    }).join('') +
      (state.composeImages.length < 9 ? '<button class="compose-add" id="composeAdd">＋</button>' : '');
  }

  function openCompose() {
    state.composeImages = [];
    openModal('发表动态',
      '<label class="field"><span class="field-label">这一刻的想法</span>' +
      '<textarea id="composeText" rows="4" maxlength="1000" placeholder="说点什么…"></textarea></label>' +
      '<div class="field"><span class="field-label">图片（最多 9 张）</span>' +
      '<input type="file" id="composeFiles" accept="image/*" multiple hidden>' +
      '<div class="compose-images" id="composeImages"></div></div>',
      '<button class="btn-primary" id="doPublish">发表</button>');
    renderComposeImages();
    $('doPublish').addEventListener('click', publishMoment);
    $('composeImages').addEventListener('click', function (e) {
      var rm = e.target.closest('[data-remove-img]');
      if (rm) {
        state.composeImages.splice(Number(rm.getAttribute('data-remove-img')), 1);
        renderComposeImages();
      } else if (e.target.closest('#composeAdd')) {
        $('composeFiles').click();
      }
    });
    $('composeFiles').addEventListener('change', function (e) {
      var files = Array.prototype.slice.call(e.target.files || []);
      files.forEach(function (file) {
        if (state.composeImages.length >= 9) return;
        if (file.size > 8 * 1024 * 1024) { toast('单张图片不能超过 8MB', 'error'); return; }
        var reader = new FileReader();
        reader.onload = function () {
          api('/upload', { method: 'POST', body: JSON.stringify({ dataUrl: String(reader.result) }) })
            .then(function (d) {
              state.composeImages.push(d.url);
              renderComposeImages();
            })
            .catch(function (err) { toast(err.message, 'error'); });
        };
        reader.readAsDataURL(file);
      });
      e.target.value = '';
    });
  }

  function publishMoment() {
    var text = $('composeText').value.trim();
    if (!text && !state.composeImages.length) return toast('写点什么，或者发张图', 'error');
    var btn = $('doPublish');
    btn.disabled = true;
    api('/moments', {
      method: 'POST',
      body: JSON.stringify({ content: text, images: state.composeImages })
    }).then(function (data) {
      closeModal();
      // WebSocket 广播可能比这个响应先到，用 patchMoment 按 id 去重，避免出现两条
      patchMoment(data.moment);
      toast('已发表');
    }).catch(function (err) { toast(err.message, 'error'); })
      .then(function () { btn.disabled = false; });
  }

  /* --------------------------------------------------------------- 数据 */

  function cacheUsers(list) {
    (list || []).forEach(function (u) {
      if (u && u.id) state.userCache[u.id] = u;
    });
  }

  function loadChats() {
    return api('/chats').then(function (data) {
      state.chats = data.chats || [];
      state.chats.forEach(function (c) {
        (c.memberIds || []).forEach(function (id) { state.userCache[id] = state.userCache[id] || { id: id }; });
      });
      renderChats();
    });
  }

  function loadContacts() {
    return api('/contacts').then(function (data) {
      state.friends = data.friends || [];
      state.incoming = data.incoming || [];
      state.outgoing = data.outgoing || [];
      cacheUsers(state.friends);
      renderFriends();
    });
  }

  function loadMessages(chatId) {
    return api('/chats/' + encodeURIComponent(chatId) + '/messages?limit=60').then(function (data) {
      state.messages[chatId] = data.messages || [];
      data.messages.forEach(function (m) {
        state.userCache[m.senderId] = state.userCache[m.senderId] ||
          { id: m.senderId, nickname: m.senderName, avatar: m.senderAvatar };
      });
      if (data.chat) upsertChat(data.chat);
      renderMessages();
    });
  }

  function markRead(chatId) {
    var chat = state.chats.find(function (c) { return c.id === chatId; });
    if (chat) { chat.unread = 0; renderChats(); }
    if (!wsSend({ type: 'read', chatId: chatId })) {
      api('/chats/' + encodeURIComponent(chatId) + '/read', { method: 'POST' }).catch(function () {});
    }
  }

  function openChat(chatId) {
    state.activeChatId = chatId;
    var chat = state.chats.find(function (c) { return c.id === chatId; });
    if (!chat) return;
    $('emptyChat').hidden = true;
    $('chatPane').hidden = false;
    $('chatTitle').textContent = chat.title;
    renderTopbar();
    if (chat.type === 'group') {
      $('chatSubText').textContent = chat.memberCount + ' 位成员';
      $('chatStatusDot').hidden = true;
      var cb0 = $('callBtn');
      if (cb0) cb0.hidden = true;
    } else {
      var otherId = (chat.memberIds || []).find(function (id) { return id !== state.me.id; });
      applyHeadStatus(otherId);
      var cb1 = $('callBtn');
      if (cb1) cb1.hidden = false;
    }
    var headPeer = chat.type === 'direct' ? ((chat.memberIds || []).find(function (id) { return id !== state.me.id; }) || '') : '';
    var headAv = $('chatAvatar');
    headAv.classList.toggle('js-avatar-link', !!headPeer);
    if (headPeer) { headAv.setAttribute('data-goto-moments', headPeer); headAv.setAttribute('title', '看 TA 的朋友圈'); }
    else { headAv.removeAttribute('data-goto-moments'); headAv.removeAttribute('title'); }
    headAv.innerHTML = chat.avatar
      ? '<img src="' + esc(chat.avatar) + '" alt="">'
      : esc(initials(chat.title));
    markOfflineAvatars();
    document.querySelector('.app').classList.add('show-chat');
    $('momentsPane').hidden = true;
    state.panel = 'chats';
    document.querySelectorAll('.side-tab').forEach(function (t) {
      t.classList.toggle('is-active', t.getAttribute('data-panel') === 'chats');
    });
    renderChats();
    loadMessages(chatId).then(function () { markRead(chatId); });
  }

  function openDirectWith(userId) {
    api('/chats/direct', { method: 'POST', body: JSON.stringify({ userId: userId }) })
      .then(function (data) {
        upsertChat(data.chat);
        openChat(data.chat.id);
        state.panel = 'chats';
        switchPanel('chats');
      })
      .catch(function (err) { toast(err.message, 'error'); });
  }

  /* --------------------------------------------------------------- 发送 */

  /* ------------------------------------------------------------ 语音消息 */

  var VOICE_MAX_MS = 60000;   // 微信同款：最长 60 秒
  var VOICE_CANCEL_DY = 60;   // 上滑超过这个距离就是「取消发送」
  var voice = null;
  var voiceMode = false;

  function voiceSupported() {
    return !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia && window.MediaRecorder);
  }

  function pickVoiceMime() {
    var list = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus', 'audio/mp4'];
    for (var i = 0; i < list.length; i++) {
      if (window.MediaRecorder && MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported(list[i])) return list[i];
    }
    return '';
  }

  /** 键盘 / 语音 两种输入模式来回切，和微信一样 */
  function setVoiceMode(on) {
    voiceMode = !!on;
    $('composerInput').hidden = voiceMode;
    $('voiceRow').hidden = !voiceMode;
    $('sendBtn').style.display = voiceMode ? 'none' : '';
    document.querySelector('.enter-hint').style.display = voiceMode ? 'none' : '';
    $('voiceBtn').classList.toggle('is-voice-mode', voiceMode);
    $('voiceBtn').title = voiceMode ? '切换到键盘' : '语音';
    $('voiceBtn').innerHTML = voiceMode
      ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><rect x="2.6" y="6.2" width="18.8" height="11.6" rx="2.4"/><path d="M6.4 9.6h.01M9.4 9.6h.01M12.4 9.6h.01M15.4 9.6h.01M18 9.6h.01M6.4 12.6h.01M9.4 12.6h.01M12.4 12.6h.01M15.4 12.6h.01M18 12.6h.01M8 15.4h8"/></svg>'
      : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="9.2" y="3.2" width="5.6" height="10.6" rx="2.8"/><path d="M5.6 11.4a6.4 6.4 0 0 0 12.8 0"/><path d="M12 17.8v3"/></svg>';
    if (!voiceMode) $('composerInput').focus();
  }

  function voiceOverlay(show, cancel) {
    var ov = $('voiceOverlay');
    if (!ov) return;
    ov.hidden = !show;
    if (!show) return;
    $('voicePanel').classList.toggle('is-cancel', !!cancel);
    $('voiceOverlayTip').textContent = cancel ? '松开手指，取消发送' : '松开发送，上滑取消';
  }

  function paintLevels() {
    if (!voice || !voice.analyser) return;
    var bars = $('voiceLevels').children;
    var buf = new Uint8Array(voice.analyser.frequencyBinCount);
    voice.analyser.getByteTimeDomainData(buf);
    var sum = 0;
    for (var i = 0; i < buf.length; i++) { var v2 = (buf[i] - 128) / 128; sum += v2 * v2; }
    var rms = Math.sqrt(sum / buf.length);
    var level = Math.max(0.08, Math.min(1, rms * 4.2));
    for (var b = 0; b < bars.length; b++) {
      var center = 1 - Math.abs(b - (bars.length - 1) / 2) / ((bars.length - 1) / 2);
      var h = Math.round(18 + level * 78 * (0.45 + center * 0.75) * (0.7 + Math.random() * 0.5));
      bars[b].style.height = Math.min(96, h) + '%' ;
    }
  }

  function voiceTick() {
    if (!voice) return;
    var ms = Date.now() - voice.startedAt;
    var sec = Math.floor(ms / 1000);
    var left = Math.max(0, Math.ceil((VOICE_MAX_MS - ms) / 1000));
    $('voiceOverlayTime').textContent = sec >= 1
      ? (left <= 10 ? '还可以说 ' + left + ' 秒' : Math.floor(sec / 60) + ':' + ('0' + (sec % 60)).slice(-2))
      : '0:00';
    paintLevels();
    if (ms >= VOICE_MAX_MS) stopVoice(true);
  }

  function startVoice() {
    if (voice) return;
    if (!state.activeChatId) return toast('先打开一个会话', 'error');
    if (!voiceSupported()) return toast('这个浏览器不支持录音', 'error');
    navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } })
      .then(function (stream) {
        var mime = pickVoiceMime();
        var rec = mime ? new MediaRecorder(stream, { mimeType: mime }) : new MediaRecorder(stream);
        var v = { stream: stream, rec: rec, chunks: [], startedAt: Date.now(), timer: null, stopSend: true, cancelZone: false };
        voice = v;
        // ondataavailable 要用闭包里的 v：停录时 voice 会先被清空，最后一段音频就落在 onstop 之前
        rec.ondataavailable = function (e) { if (e.data && e.data.size) v.chunks.push(e.data); };
        rec.onstop = function () { finishVoice(v); };
        rec.start();
        try {
          var AC = window.AudioContext || window.webkitAudioContext;
          v.audioCtx = new AC();
          var src = v.audioCtx.createMediaStreamSource(stream);
          v.analyser = v.audioCtx.createAnalyser();
          v.analyser.fftSize = 512;
          src.connect(v.analyser);
        } catch (e) { v.analyser = null; }
        v.timer = setInterval(voiceTick, 120);
        $('voiceHoldBtn').classList.add('is-recording');
        $('voiceHoldBtn').textContent = '松开 发送';
        voiceOverlay(true, false);
      })
      .catch(function (err) { voiceFail(err); });
  }

  function stopVoice(send) {
    if (!voice) return;
    var v = voice;
    voice = null;
    if (v.timer) clearInterval(v.timer);
    v.stopSend = send !== false;
    try { v.rec.stop(); } catch (e) { finishVoice(v); }
  }

  function finishVoice(v) {
    if (!v || v.done) return;
    v.done = true;
    if (v.stream) v.stream.getTracks().forEach(function (t) { t.stop(); });
    if (v.audioCtx) { try { v.audioCtx.close(); } catch (e) { /* 忽略 */ } }
    voiceOverlay(false, false);
    $('voiceHoldBtn').classList.remove('is-recording');
    $('voiceHoldBtn').textContent = '按住 说话';
    var blob = new Blob(v.chunks, { type: (v.rec && v.rec.mimeType) || 'audio/webm' });
    var ms = Date.now() - v.startedAt;
    var sec = Math.max(1, Math.round(ms / 1000));
    if (!v.stopSend) { toast('已取消发送'); return; }
    if (ms < 1000) { toast('说话时间太短'); return; }   // 微信也是这句
    sendVoice(blob, sec);
  }

  function bindVoiceHold() {
    var hold = $('voiceHoldBtn');
    if (!hold) return;
    var startY = 0;
    var holding = false;

    hold.addEventListener('pointerdown', function (e) {
      if (holding) return;
      holding = true;
      startY = e.clientY;
      try { hold.setPointerCapture && hold.setPointerCapture(e.pointerId); } catch (err) { /* 忽略 */ }
      startVoice();
      e.preventDefault();
    });
    // 松开/取消/窗口失焦时一定要释放鼠标捕获，否则鼠标会被"锁住"
    function releaseHoldCapture(ev) {
      try {
        if (!hold.releasePointerCapture) return;
        if (ev && typeof ev.pointerId === 'number' && hold.hasPointerCapture && !hold.hasPointerCapture(ev.pointerId)) return;
        hold.releasePointerCapture(ev && typeof ev.pointerId === 'number' ? ev.pointerId : 1);
      } catch (err) { /* 忽略 */ }
    }
    hold.addEventListener('pointerup', releaseHoldCapture);
    hold.addEventListener('pointercancel', releaseHoldCapture);
    window.addEventListener('blur', function () { holding = false; releaseHoldCapture(); });
    document.addEventListener('visibilitychange', function () { if (document.hidden) { holding = false; releaseHoldCapture(); } });

    hold.addEventListener('pointermove', function (e) {
      if (!holding || !voice) return;
      var dy = e.clientY - startY;
      var cancel = dy < -VOICE_CANCEL_DY;
      if (cancel !== voice.cancelZone) {
        voice.cancelZone = cancel;
        voiceOverlay(true, cancel);
      }
    });

    function release() {
      if (!holding) return;
      holding = false;
      if (!voice) return;
      stopVoice(!voice.cancelZone);
    }
    hold.addEventListener('pointerup', release);
    hold.addEventListener('pointercancel', release);
    hold.addEventListener('pointerleave', function (e) {
      // 拖到按钮外面：继续录音，只有松开才结算（微信也是这样）
      if (!holding || !voice) return;
      if (e.clientY - startY < -VOICE_CANCEL_DY) { voice.cancelZone = true; voiceOverlay(true, true); }
    });
  }

  /** 录音起不来时，把真正的原因说清楚，并指出「选语音文件」这条备用路 */
  function voiceFail(err) {
    var name = (err && err.name) || '';
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      toast('这个浏览器/环境不支持录音（需要 https 或 localhost）', 'error');
    } else if (name === 'NotFoundError' || name === 'DevicesNotFoundError' || name === 'OverconstrainedError') {
      toast('这台电脑没检测到麦克风，可以点右边「选语音文件」直接发一段音频', 'error');
    } else if (name === 'NotAllowedError' || name === 'SecurityError') {
      toast('麦克风权限被拒绝了：点地址栏左边的图标 → 允许麦克风 → 刷新页面', 'error');
    } else if (name === 'NotReadableError' || name === 'TrackStartError') {
      toast('麦克风被别的程序占用了（QQ / 微信 / 会议软件在录音），关掉再试', 'error');
    } else {
      toast('录音启动失败：' + ((err && err.message) || name || '未知原因'), 'error');
    }
    var fb = $('voiceFileBtn');
    if (fb) {
      fb.classList.add('is-attention');
      setTimeout(function () { fb.classList.remove('is-attention'); }, 3600);
    }
  }

  /** 没有麦克风时用：选一个音频文件，当成语音消息发出去 */
  function sendVoiceFile(file) {
    if (!file) return;
    if (!state.activeChatId) return toast('先打开一个会话', 'error');
    if (file.size > 20 * 1024 * 1024) return toast('音频不能超过 20MB', 'error');
    var url = URL.createObjectURL(file);
    var probe = new Audio();
    var done = false;
    var finish = function () {
      if (done) return;
      done = true;
      var sec = (isFinite(probe.duration) && probe.duration > 0) ? Math.round(probe.duration) : 0;
      sendVoice(file, sec || 1);
      URL.revokeObjectURL(url);
    };
    probe.addEventListener('loadedmetadata', finish);
    probe.addEventListener('error', finish);
    setTimeout(finish, 1500);  // 有些格式读不出时长，别卡住
    probe.preload = 'metadata';
    probe.src = url;
  }

  function sendVoice(blob, sec) {
    var chatId = state.activeChatId;
    if (!chatId) return;
    if (blob.size > 12 * 1024 * 1024) return toast('语音太长了', 'error');
    var reader = new FileReader();
    reader.onload = function () {
      // 录出来的 dataURL 可能带 ;codecs=opus，服务端只认干净的 mime
      var dataUrl = String(reader.result).replace(/^data:[^,]*?;codecs=[^;,]+/, function (head) {
        return head.replace(/;codecs=[^;,]+/, '');
      });
      var ext = (blob.type || '').indexOf('mp4') !== -1 ? 'm4a' : ((blob.type || '').indexOf('ogg') !== -1 ? 'ogg' : ((blob.type || '').indexOf('mpeg') !== -1 ? 'mp3' : ((blob.type || '').indexOf('wav') !== -1 ? 'wav' : 'webm')));
      api('/upload', { method: 'POST', body: JSON.stringify({ dataUrl: dataUrl, filename: 'voice.' + ext }) })
        .then(function (d) {
          var payload = JSON.stringify({ url: d.url, dur: sec, bytes: d.bytes });
          var clientId = 'c' + Date.now();
          var local = {
            id: clientId, chatId: chatId, senderId: state.me.id, kind: 'audio',
            content: payload, createdAt: new Date().toISOString(), recalled: false, pending: true
          };
          if (!state.messages[chatId]) state.messages[chatId] = [];
          state.messages[chatId].push(local);
          renderMessages();
          if (!wsSend({ type: 'send', chatId: chatId, kind: 'audio', content: payload, clientId: clientId })) {
            api('/chats/' + encodeURIComponent(chatId) + '/messages', {
              method: 'POST', body: JSON.stringify({ kind: 'audio', content: payload, clientId: clientId })
            }).then(function (r) { replacePending(chatId, clientId, r.message); })
              .catch(function (e) { toast(e.message, 'error'); removePending(chatId, clientId); });
          }
        })
        .catch(function (err) { toast(err.message, 'error'); });
    };
    reader.readAsDataURL(blob);
  }

  function voicePayload(content) {
    try {
      var d = JSON.parse(content);
      if (d && d.url) return d;
    } catch (e) { /* 老数据可能只存了 url */ }
    return { url: String(content || ''), dur: 0 };
  }

  // QQ 那种语音气泡：喇叭 + 三道声波弧 + 时长，播放键永远靠近头像那一侧
  var voiceSpeakerSvg = '<svg class="voice-speaker" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M4.2 9.4h3.1l4-3.2v11.6l-4-3.2H4.2z" fill="currentColor" stroke="none"/><path class="vs-wave vs-w1" d="M14.4 9.6a3.6 3.6 0 0 1 0 4.8"/><path class="vs-wave vs-w2" d="M16.8 7.6a6.4 6.4 0 0 1 0 8.8"/><path class="vs-wave vs-w3" d="M19.2 5.6a9.2 9.2 0 0 1 0 12.8"/></svg>';

  function voicePlayedSet() {
    if (!state.voicePlayed) {
      var raw = [];
      try { raw = JSON.parse(localStorage.getItem('chris-voice-played') || '[]'); } catch (e) { raw = []; }
      state.voicePlayed = {};
      (Array.isArray(raw) ? raw : []).slice(-500).forEach(function (id) { state.voicePlayed[id] = 1; });
    }
    return state.voicePlayed;
  }

  function voiceMarkPlayed(id) {
    if (!id) return;
    var set = voicePlayedSet();
    if (set[id]) return;
    set[id] = 1;
    try {
      var keys = Object.keys(set);
      localStorage.setItem('chris-voice-played', JSON.stringify(keys.slice(-500)));
    } catch (e) { /* 忽略 */ }
    var sel = '#messages .voice-bubble[data-msg="' + id + '"]';
    var dot = document.querySelector(sel + ' .voice-dot-unread');
    if (dot) dot.remove();
    var box = document.querySelector(sel);
    if (box) { box.classList.add('is-played'); box.classList.remove('is-playing'); }
  }

  function voiceBubbleHtml(m) {
    var d = voicePayload(m.content);
    var secs = d.dur || 0;
    var w = Math.round(104 + Math.min(secs || 2, 60) * 1.7);   // 时长越长气泡越宽
    var mine = m.senderId === state.me.id;
    var played = !!voicePlayedSet()[m.id];
    return '<div class="bubble voice-bubble' + (mine ? ' is-mine' : '') + (played ? ' is-played' : '') + '"' +
      ' data-voice="' + esc(d.url) + '" data-msg="' + esc(m.id) + '" style="width:' + w + 'px">' +
      '<span class="voice-icon">' + voiceSpeakerSvg + '</span>' +
      '<span class="voice-meta">' +
        '<span class="voice-dur">' + (d.dur ? d.dur + '″' : '') + '</span>' +
        (mine ? '' : '<span class="voice-dot-unread" title="没听过"></span>') +
      '</span>' +
      '<audio preload="metadata" src="' + esc(d.url) + '"></audio>' +
    '</div>';
  }

  function bindVoicePlayers() {
    document.querySelectorAll('#messages .voice-bubble').forEach(function (box) {
      var audio = box.querySelector('audio');
      var dur = box.querySelector('.voice-dur');
      if (!audio) return;
      if (!dur.textContent) {
        audio.addEventListener('loadedmetadata', function () {
          if (!dur.textContent && isFinite(audio.duration) && audio.duration > 0) {
            dur.textContent = Math.max(1, Math.round(audio.duration)) + '″';
          }
        });
        audio.load();
      }
    });
  }

  function toggleVoice(box) {
    var audio = box.querySelector('audio');
    if (!audio) return;
    voiceMarkPlayed(box.getAttribute('data-msg'));
    document.querySelectorAll('#messages .voice-bubble.is-playing').forEach(function (other) {
      if (other === box) return;
      other.classList.remove('is-playing');
      var oa = other.querySelector('audio');
      if (oa) oa.pause();
    });
    if (audio.paused) {
      var p = audio.play();
      box.classList.add('is-playing');
      if (p && p.catch) p.catch(function () { box.classList.remove('is-playing'); toast('这个浏览器不让自动播放，再点一下试试', 'error'); });
      audio.onended = function () { box.classList.remove('is-playing'); };
    } else {
      audio.pause();
      box.classList.remove('is-playing');
    }
  }

  /* ------------------------------------------------------------ 语音通话 */

  var call = null;   // { id, peerId, peerName, peerAvatar, role, pc, stream, timer, muted }

  function callSupported() {
    return !!(window.RTCPeerConnection && navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
  }

  function callEls() {
    return {
      layer: $('callLayer'), card: $('callCard'), avatar: $('callAvatar'), name: $('callName'),
      status: $('callStatus'), timer: $('callTimer'), stage: $('callStage'), stageText: $('callStageText'),
      accept: $('callAcceptBtn'), hangup: $('callHangupBtn'), mute: $('callMuteBtn'), audio: $('callAudio'),
      cam: $('callCamBtn'), flip: $('callFlipBtn'), remote: $('callRemoteVideo'), local: $('callLocalVideo'), peerAvatar: $('callPeerAvatar')
    };
  }

  function callSetPhase(phase, peer) {
    var el = callEls();
    var media = (call && call.media) || 'audio';
    var video = media === 'video';
    var live = (phase === 'active' || phase === 'calling' || phase === 'connecting');
    el.layer.hidden = false;
    el.card.setAttribute('data-phase', phase);
    el.card.setAttribute('data-media', media);
    el.card.classList.toggle('is-video', video && phase !== 'incoming');
    el.avatar.innerHTML = peer && peer.avatar ? '<img src="' + esc(peer.avatar) + '" alt="">' : esc(initials((peer && peer.name) || '?'));
    el.name.textContent = (peer && peer.name) || '—';
    el.accept.hidden = phase !== 'incoming';
    var localVideoOff = !!(call && (call.camOff || call.localVideoFailed));
    el.card.classList.toggle('is-camoff', video && localVideoOff);
    if (el.local) el.local.classList.toggle('is-placeholder', video && localVideoOff);
    if (el.cam) el.cam.classList.toggle('is-off', !!(call && call.camOff));
    if (el.peerAvatar) {
      // 语音通话不碰这个层（它是视频通话专用的头像占位）
      if (video) {
        el.peerAvatar.innerHTML = (peer && peer.avatar) ? '<img src="' + esc(peer.avatar) + '" alt="">' : esc(initials((peer && peer.name) || '?'));
      } else {
        el.peerAvatar.innerHTML = '';
      }
    }
    el.mute.hidden = !live;
    var wantsVideo = !!(call && call.wantsVideo);
    el.cam.hidden = !(wantsVideo && live);
    el.flip.hidden = !(video && live);
    if (wantsVideo && !video) el.cam.title = '打开摄像头';
    el.stage.hidden = !live;
    if (phase === 'incoming') el.status.textContent = video ? '邀请你视频通话…' : '邀请你语音通话…';
    else if (phase === 'calling') el.status.textContent = video ? '正在视频呼叫…' : '正在呼叫…';
    else if (phase === 'connecting') el.status.textContent = '已接通，正在连接…';
    else if (phase === 'active') el.status.textContent = video ? '视频通话中' : '语音通话中';
    else if (phase === 'ended') el.status.textContent = '通话已结束';
  }

  function callClose(delay) {
    wsAudioStop();
    if (call && call.timer) clearInterval(call.timer);
    if (call && call.connectTimer) clearTimeout(call.connectTimer);
    if (call && call.pc) { try { call.pc.close(); } catch (e) { /* 忽略 */ } }
    if (call && call.stream) call.stream.getTracks().forEach(function (t) { t.stop(); });
    call = null;
    setTimeout(function () {
      var el = callEls();
      el.layer.hidden = true;
      el.audio.srcObject = null;
      if (el.remote) el.remote.srcObject = null;
      if (el.local) el.local.srcObject = null;
      el.card.classList.remove('is-video', 'is-camoff', 'has-remote-video');
      el.card.removeAttribute('data-media');
      el.timer.hidden = true;
      el.card.setAttribute('data-phase', '');
    }, delay || 900);
  }

  function callStartTimer() {
    var el = callEls();
    el.timer.hidden = false;
    var t0 = Date.now();
    if (call && call.timer) clearInterval(call.timer);
    var tick = function () {
      var s = Math.floor((Date.now() - t0) / 1000);
      el.timer.textContent = ('0' + Math.floor(s / 60)).slice(-2) + ':' + ('0' + (s % 60)).slice(-2);
    };
    tick();
    if (call) call.timer = setInterval(tick, 500);
  }

  var CALL_STUN_DEFAULT = [
    'stun:stun.l.google.com:19302',
    'stun:stun1.l.google.com:19302',
    'stun:stun.cloudflare.com:3478',
    'stun:stun.miwifi.com:3478'
  ];

  /** 通话用的 ICE 服务器：后台「语音通话」里填了就用它，没填就用默认的几个公共 STUN */
  /** 把远端候选先存起来：远端描述还没设好时直接 addIceCandidate 会报错，候选就白丢了 */
  function callAddRemoteCandidate(cand) {
    if (!call || !cand) return;
    if (call.pc && call.pc.remoteDescription) {
      call.pc.addIceCandidate(new RTCIceCandidate(cand)).catch(function () { /* 单条失败不影响其它 */ });
      return;
    }
    call.pendingCandidates.push(cand);
  }

  function callFlushCandidates() {
    if (!call || !call.pc || !call.pc.remoteDescription) return;
    var list = call.pendingCandidates || [];
    call.pendingCandidates = [];
    list.forEach(function (cand) {
      call.pc.addIceCandidate(new RTCIceCandidate(cand)).catch(function () { /* 忽略 */ });
    });
  }

  /** 等 ICE 收集完（最多 3 秒），这样 SDP 里自带全部候选，不依赖逐条 trickle */
  function callWaitIce(pc) {
    return new Promise(function (resolve) {
      if (pc.iceGatheringState === 'complete') return resolve();
      var done = false;
      var finish = function () { if (done) return; done = true; pc.removeEventListener('icegatheringstatechange', onChange); resolve(); };
      var onChange = function () { if (pc.iceGatheringState === 'complete') finish(); };
      pc.addEventListener('icegatheringstatechange', onChange);
      setTimeout(finish, 3000);
    });
  }

  function callIceServers() {
    var raw = String((state.branding && state.branding.iceServers) || '').trim();
    var list = [];
    if (raw) {
      try {
        var parsed = JSON.parse(raw);
        if (Array.isArray(parsed)) list = parsed;
        else if (typeof parsed === 'string') list = [parsed];
      } catch (e) {
        list = raw.split(/[\n,]+/).map(function (x) { return x.trim(); }).filter(Boolean);
      }
    }
    var servers = list.map(function (item) {
      if (typeof item === 'string') return { urls: item };
      if (item && item.urls) return item;
      return null;
    }).filter(Boolean).filter(function (s) {
      /* 只留真正像地址的：以前后台配置格式不对时，这里会塞进 "[object Object]"，
         Chrome 直接当没有 ICE 服务器 → 通话永远卡在「正在连接」 */
      var u = s.urls;
      if (typeof u === 'string') return /^(stun|turn|turns):/i.test(u);
      if (Object.prototype.toString.call(u) === '[object Array]') {
        return u.some(function (x) { return /^(stun|turn|turns):/i.test(String(x)); });
      }
      return false;
    });
    if (!servers.length) servers = [{ urls: CALL_STUN_DEFAULT }];
    /* 兜底：把自己服务器上的 TURN 也加上（TCP 那条才是通的），
       保证不管后台配置成什么样，通话都有中转可用 */
    var h = location.hostname;
    if (h) {
      servers.push({
        /* 只留 TCP：这台服务器的 UDP 中继经常被运营商挡，而且两端必须用同一种通道
           才能配得上对（一边 TCP 一边 UDP 是连不通的） */
        urls: ['turn:' + h + ':3478?transport=tcp'],
        username: 'chris', credential: 'chris1234'
      });
    }
    return servers;
  }

  /** 一直连不上多半是打洞失败，别让它无限转圈 */
  function callStartConnectTimeout() {
    if (!call) return;
    if (call.connectTimer) clearTimeout(call.connectTimer);
    call.connectTimer = setTimeout(function () {
      if (!call || call.started) return;
      callEls().status.textContent = '连接超时';
      toast('连不上对方：两边网络无法直连，需要在后台「语音通话」里配一个 TURN 服务器', 'error');
      callHangup();
    }, 25000);
  }

  function callMakePc() {
    /* 外网通话（跑在公网域名上）：一律走服务器中继，不然 4G ↔ 家里宽带
       这种组合经常只连上一半（一边听得到、一边听不到），甚至完全连不上。
       局域网（192.168.x / 10.x / localhost）还是走直连，快。 */
    var h = location.hostname || '';
    var lan = /^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(h);
    /* 公网部署：一律走中继（两端策略一致，不会再出现"一边中继一边直连"的半通） */
    var pc = new RTCPeerConnection({ iceServers: callIceServers(), iceTransportPolicy: lan ? 'all' : 'relay' });
    pc.onicecandidate = function (e) {
      /* 把候选类型记下来（排查用）：真机上连不上时，后台日志里能看到是哪一种候选 */
      if (e.candidate) {
        if (!call) return;
        if (!call.candTypes) call.candTypes = [];
        call.candTypes.push(e.candidate.type + '/' + ((e.candidate.protocol) || '?'));
      }
      // 只在 invite / accept 已经发出去之后再补候选，否则服务器收到的是「不存在的通话」
      if (e.candidate && call && (call.inviteSent || call.answerSent)) {
        wsSend({ type: 'call', action: 'ice', callId: call.id, candidate: e.candidate });
      }
    };
    pc.onicegatheringstatechange = function () {
      if (call) call.gathering = pc.iceGatheringState;
    };
    /* 网页版也把诊断报给服务器：以前只有 App 报，网页这半边是瞎的，排查很难 */
    pc.oniceconnectionstatechange = function () {
      if (!call) return;
      var c = call;
      if (pc.iceConnectionState === 'failed' || pc.iceConnectionState === 'disconnected') {
        try {
          fetch('/api/call-diag', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text: (c.answerSent ? '网页(被叫)' : '网页(主叫)') + ' ' + (c.media || 'audio')
              + ' 结果=连接失败 ice=' + pc.iceConnectionState
              + ' gathering=' + pc.iceGatheringState
              + ' 候选=' + ((c.candTypes || []).join(', ') || '无')
              + ' iceServers=' + JSON.stringify(callIceServers()).slice(0, 160) })
          });
        } catch (err) { }
      }
    };
    pc.ontrack = function (e) {
      var el = callEls();
      var stream = e.streams[0];
      if (e.track && e.track.kind === 'video') {
        // 远端画面：声音统一走 audio 元素，视频元素自己静音，不然会双重出声
        el.remote.muted = true;
        el.remote.srcObject = stream;
        el.remote.classList.remove('is-hidden');
        el.card.classList.add('has-remote-video');
        var pv = el.remote.play();
        if (pv && pv.catch) pv.catch(function () { /* 自动播放被拦，点一下接听即可 */ });
        e.track.onmute = function () { el.remote.classList.add('is-hidden'); el.card.classList.remove('has-remote-video'); };   // 对方关了摄像头
        e.track.onunmute = function () { el.remote.classList.remove('is-hidden'); el.card.classList.add('has-remote-video'); };
        return;
      }
      if (el.audio.srcObject !== stream) el.audio.srcObject = stream;
      var p = el.audio.play();
      if (p && p.catch) p.catch(function () { /* 自动播放被拦，界面里再点一下接听/免提即可 */ });
    };
    pc.onconnectionstatechange = function () {
      if (!call) return;
      var st = pc.connectionState;
      callEls().stageText.textContent = st === 'connected' ? '已接通' : (st === 'connecting' ? '连接中…' : st);
      if (st === 'connected') {
        callEls().card.setAttribute('data-phase', 'active');
        callEls().status.textContent = (call && call.media === 'video') ? '视频通话中' : '语音通话中';
        callEls().mute.hidden = false;
        if (!call.started) { call.started = true; callStartTimer(); }
      }
      if (st === 'failed') { toast('通话连接失败，可能被网络挡住了', 'error'); callHangup(); }
    };
    return pc;
  }

  function callGetMedia() {
    var audioOnly = { audio: { echoCancellation: true, noiseSuppression: true } };
    var wantVideo = !!(call && call.media === 'video');
    var constraints = wantVideo
      ? { audio: audioOnly.audio, video: { width: { ideal: 1280 }, height: { ideal: 720 }, facingMode: call.facing || 'user' } }
      : audioOnly;
    var ask = function (c) { return navigator.mediaDevices.getUserMedia(c); };
    var first = ask(constraints);
    if (wantVideo) {
      // 摄像头打不开（没有摄像头 / 权限被拒 / 被别的程序占用）时退成语音，别让整通电话失败
      first = first.catch(function (err) {
        if (!call) throw err;
        // 摄像头打不开也保持「视频通话」：自己没画面，但仍然能看到对方，随时可以补开
        call.cameraError = err;
        call.localVideoFailed = true;
        return ask(audioOnly);
      });
    }
    return first
      .then(function (stream) {
        if (!call) { stream.getTracks().forEach(function (t) { t.stop(); }); return null; }
        call.stream = stream;
        stream.getTracks().forEach(function (t) { call.pc.addTrack(t, stream); });
        var el = callEls();
        if (call.cameraError) {
          callMediaFail(call.cameraError, true);
          callSetPhase((call.role === 'callee' && !call.answerSent) ? 'connecting' : 'calling', { name: call.peerName, avatar: call.peerAvatar });
        }
        if (call.media === 'video' && el.local) {
          el.local.srcObject = stream;                 // 自己这块小窗是本地预览，不等对方
          el.local.style.transform = (call.facing || 'user') === 'user' ? 'scaleX(-1)' : 'none';
          var pv = el.local.play();
          if (pv && pv.catch) pv.catch(function () { /* 忽略 */ });
        }
        return stream;
      });
  }

  function startCall(peerId, peerName, peerAvatar, media) {
    if (call) return toast('已经在通话里了', 'error');
    if (!callSupported()) return toast('这个浏览器不支持通话', 'error');
    if (!peerId) return;
    media = media === 'video' ? 'video' : 'audio';
    var callId = 'call' + Date.now() + Math.random().toString(16).slice(2, 6);
    call = { id: callId, peerId: peerId, peerName: peerName, peerAvatar: peerAvatar || '', role: 'caller', media: media, wantsVideo: media === 'video', facing: 'user', camOff: false, pc: null, stream: null, timer: null, muted: false, pendingCandidates: [] };
    call.pc = callMakePc();
    callSetPhase('calling', { name: peerName, avatar: peerAvatar });
    callGetMedia()
      .then(function (stream) {
        if (!stream) return null;
        return call.pc.createOffer({ offerToReceiveAudio: true, offerToReceiveVideo: call.media === 'video' }).then(function (offer) {
          return call.pc.setLocalDescription(offer).then(function () {
            // 等候选收集完，把完整 SDP 一起发过去（弱网下比逐条 trickle 稳）
            return callWaitIce(call.pc).then(function () {
              var local = call.pc.localDescription || offer;
              call.inviteSent = true;
              wsSend({
                type: 'call', action: 'invite', callId: callId, toUserId: peerId, media: call.media,
                sdp: { type: local.type, sdp: local.sdp }
              });
              callSetPhase('calling', { name: peerName, avatar: peerAvatar });
            });
          });
        });
      })
      .catch(function (err) {
        call = null;
        callClose(0);
        callMediaFail(err, call ? call.media === 'video' : false);
      });
  }

  function acceptCall() {
    if (!call || call.role !== 'callee') return;
    callSetPhase('connecting', { name: call.peerName, avatar: call.peerAvatar });
    callGetMedia()
      .then(function (stream) {
        if (!stream) return null;
        return call.pc.createAnswer().then(function (answer) {
          return call.pc.setLocalDescription(answer).then(function () {
            return callWaitIce(call.pc).then(function () {
              var local = call.pc.localDescription || answer;
              call.answerSent = true;
              wsSend({ type: 'call', action: 'accept', callId: call.id, sdp: { type: local.type, sdp: local.sdp } });
              callStartConnectTimeout();
              if (call.media !== 'video') wsAudioStart();   // 语音：接起来就走服务器转发
            });
          });
        });
      })
      .catch(function (err) {
        wsSend({ type: 'call', action: 'reject', callId: call.id });
        var wasVideo = call.media === 'video';
        callClose(0);
        callMediaFail(err, wasVideo);
      });
  }

  function callHangup() {
    if (!call) return;
    callEls().status.textContent = call.started ? '通话已结束' : (call.role === 'caller' ? '已取消' : '已拒绝');
    callEls().accept.hidden = true;
    wsSend({ type: 'call', action: call.started ? 'hangup' : (call.role === 'caller' ? 'cancel' : 'reject'), callId: call.id });
    callClose(300);
  }

  /* ============================================================
     服务器转发语音（兜底通道）
     有些运营商把到 TURN 的通道全挡了（手机拿不到任何中继候选），WebRTC 永远接不通。
     这条路走长连接（wss/443）：麦克风 → 16kHz 单声道 Int16 → 40ms 一帧 → base64 发出去；
     收到对方的帧直接排到播放队列。App 端用的是同一套格式。
     ============================================================ */
  var wsAudio = { play: null, in: null, proc: null, src: null, acc: new Int16Array(0), on: false };

  /* 网页这半边以前是"瞎的"：出了问题我看不到。这里把关键动作报给服务器日志。 */
  function wsDiag(text) {
    try {
      fetch('/api/call-diag', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text: '网页 ' + text })
      });
    } catch (e) { }
  }

  function wsAudioStart() {
    if (wsAudio.on || !call) return;
    var Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return;
    try {
      wsAudio.play = new Ctx({ sampleRate: 16000 });
      wsAudio.in = new Ctx({ sampleRate: 16000 });
    } catch (e) {
      wsDiag('创建音频上下文失败: ' + e);
      return;
    }
    /* 浏览器有自动播放限制：上下文是 suspended 的话，采集和播放都不会工作，
       必须显式 resume（这次是用户点了电话按钮进来的，属于用户手势，能 resume 成功） */
    try { if (wsAudio.in.state === 'suspended') wsAudio.in.resume(); } catch (e) { }
    try { if (wsAudio.play.state === 'suspended') wsAudio.play.resume(); } catch (e) { }
    if (call.stream) {
      try {
        wsAudio.src = wsAudio.in.createMediaStreamSource(call.stream);
        wsAudio.proc = wsAudio.in.createScriptProcessor(1024, 1, 1);
        wsAudio.proc.onaudioprocess = function (e) {
          if (!call || call.muted) return;
          var f = e.inputBuffer.getChannelData(0);
          var i16 = new Int16Array(f.length);
          for (var i = 0; i < f.length; i++) {
            var s = Math.max(-1, Math.min(1, f[i]));
            i16[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
          }
          var all = new Int16Array(wsAudio.acc.length + i16.length);
          all.set(wsAudio.acc); all.set(i16, wsAudio.acc.length);
          wsAudio.acc = all;
          while (wsAudio.acc.length >= 640) {                 // 40ms 一帧
            var frame = wsAudio.acc.slice(0, 640);
            wsAudio.acc = wsAudio.acc.slice(640);
            wsSend({ type: 'call', action: 'audio', callId: call.id, data: wsInt16ToB64(frame) });
          }
        };
        wsAudio.src.connect(wsAudio.proc);
        wsAudio.proc.connect(wsAudio.in.destination);
      } catch (e) {
        wsDiag('麦克风接不上: ' + e);     // 没有麦克风就只收不发
      }
    }
    wsAudio.on = true;
    wsDiag('语音走服务器转发 ✓（网页端开始采音）');
    /* 这条路一开始传声音，界面就直接算「通话中」（不用等注定失败的 ICE） */
    if (call && !call.started) {
      call.started = true;
      callEls().card.setAttribute('data-phase', 'active');
      callEls().status.textContent = call.media === 'video' ? '视频通话中' : '语音通话中';
      callEls().mute.hidden = false;
      callStartTimer();
    }
  }

  function wsAudioStop() {
    if (!wsAudio.on) return;
    wsAudio.on = false;
    try { if (wsAudio.proc) wsAudio.proc.disconnect(); } catch (e) { }
    try { if (wsAudio.src) wsAudio.src.disconnect(); } catch (e) { }
    try { if (wsAudio.in) wsAudio.in.close(); } catch (e) { }
    try { if (wsAudio.play) wsAudio.play.close(); } catch (e) { }
    wsAudio = { play: null, in: null, proc: null, src: null, acc: new Int16Array(0), on: false };
  }

  function wsInt16ToB64(i16) {
    var b = new Uint8Array(i16.buffer);
    var s = '';
    for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s);
  }

  function wsAudioPlay(b64) {
    if (!wsAudio.on) wsAudioStart();
    if (!wsAudio.play) return;
    try {
      var bin = atob(b64);
      var n = bin.length >> 1;
      if (!n) return;
      var buf = wsAudio.play.createBuffer(1, n, 16000);
      var ch = buf.getChannelData(0);
      for (var i = 0; i < n; i++) {
        var v = (bin.charCodeAt(i * 2 + 1) << 8) | bin.charCodeAt(i * 2);
        if (v >= 0x8000) v -= 0x10000;
        ch[i] = v / 32768;
      }
      var s = wsAudio.play.createBufferSource();
      s.buffer = buf;
      s.connect(wsAudio.play.destination);
      s.start();
    } catch (e) { }
  }

  function toggleCallMute() {
    if (!call || !call.stream) return;
    call.muted = !call.muted;
    call.stream.getAudioTracks().forEach(function (t) { t.enabled = !call.muted; });
    callEls().mute.classList.toggle('is-on', call.muted);
    toast(call.muted ? '已静音' : '已取消静音');
  }

  /** 通话时拿不到摄像头/麦克风，把原因说清楚（和「录音」那套提示分开） */
  function callMediaFail(err, video) {
    var name = (err && err.name) || '';
    var what = video ? '摄像头' : '麦克风';
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      toast('这个浏览器/环境不支持通话（需要 https 或 localhost）', 'error');
    } else if (name === 'NotFoundError' || name === 'DevicesNotFoundError' || name === 'OverconstrainedError') {
      toast('这台设备没检测到' + what + (video ? '，先用语音接通；点底部的摄像机可以重试' : ''), 'error');
    } else if (name === 'NotAllowedError' || name === 'SecurityError') {
      toast(what + '权限被拒绝了：点地址栏左边的图标 → 允许' + what + '；先用语音接通，授权后点底部摄像机可重试', 'error');
    } else if (name === 'NotReadableError' || name === 'TrackStartError' || name === 'AbortError') {
      toast(what + '被别的程序占用了（QQ / 微信 / 会议软件 / 相机），关掉再试；先用语音接通，点底部摄像机可重试', 'error');
    } else {
      toast('通话启动失败：' + ((err && err.message) || name || '未知原因'), 'error');
    }
  }

  /** 关 / 开自己的摄像头（本来就没打开时，改成“重试打开”） */
  function toggleCallCamera() {
    if (!call || !call.stream) return;
    var tracks = call.stream.getVideoTracks();
    if (!tracks.length) { retryCallCamera(); return; }
    call.camOff = !call.camOff;
    tracks.forEach(function (t) { t.enabled = !call.camOff; });
    var el = callEls();
    el.card.classList.toggle('is-camoff', call.camOff);
    el.cam.classList.toggle('is-off', call.camOff);
    el.cam.title = call.camOff ? '打开摄像头' : '关闭摄像头';
    toast(call.camOff ? '摄像头已关闭' : '摄像头已打开');
  }

  /** 前置 / 后置切换（手机上有用，电脑上一般只有一个摄像头） */
  function flipCallCamera() {
    if (!call || !call.stream) return;
    var track = call.stream.getVideoTracks()[0];
    if (!track || !track.applyConstraints) return toast('这个设备不支持切换摄像头', 'error');
    var next = (call.facing || 'user') === 'user' ? 'environment' : 'user';
    track.applyConstraints({ facingMode: next }).then(function () {
      call.facing = next;
      var el = callEls();
      if (el.local) el.local.style.transform = next === 'user' ? 'scaleX(-1)' : 'none';
      toast(next === 'user' ? '已切到前置摄像头' : '已切到后置摄像头');
    }).catch(function () { toast('切换摄像头失败', 'error'); });
  }

  /** 通话中重新打开摄像头：重新取流 + 重新协商（不用重新拨号） */
  function retryCallCamera() {
    if (!call || !call.pc || !call.stream) return;
    if (call.retryingCamera) return;
    call.retryingCamera = true;
    var el = callEls();
    if (el.cam) el.cam.title = '正在打开摄像头…';
    navigator.mediaDevices.getUserMedia({ video: { width: { ideal: 1280 }, height: { ideal: 720 }, facingMode: call.facing || 'user' } })
      .then(function (vs) {
        call.retryingCamera = false;
        if (!call) { vs.getTracks().forEach(function (t) { t.stop(); }); return null; }
        var track = vs.getVideoTracks()[0];
        track.onended = function () { toast('摄像头被断开了', 'error'); };
        call.stream.addTrack(track);
        call.pc.addTrack(track, call.stream);
        call.media = 'video';
        call.cameraError = null;
        call.localVideoFailed = false;
        call.camOff = false;
        if (el.local) {
          el.local.srcObject = call.stream;
          el.local.style.transform = (call.facing || 'user') === 'user' ? 'scaleX(-1)' : 'none';
          var pv = el.local.play(); if (pv && pv.catch) pv.catch(function () {});
        }
        callSetPhase(el.card.getAttribute('data-phase') || 'active', { name: call.peerName, avatar: call.peerAvatar });
        wsSend({ type: 'call', action: 'media', callId: call.id, media: 'video' });
        toast('摄像头打开了');
        return callRenegotiate();
      })
      .catch(function (err) { call.retryingCamera = false; callMediaFail(err, true); if (el.cam) el.cam.title = '打开摄像头'; });
  }

  /** 重新协商：把新加的轨道告诉对方（原来的 offer 里没有视频） */
  function callRenegotiate() {
    if (!call || !call.pc) return Promise.resolve();
    return call.pc.createOffer()
      .then(function (offer) { return call.pc.setLocalDescription(offer); })
      .then(function () { return callWaitIce(call.pc); })
      .then(function () {
        if (!call || !call.pc.localDescription) return null;
        var local = call.pc.localDescription;
        wsSend({ type: 'call', action: 'sdp', callId: call.id, sdp: { type: local.type, sdp: local.sdp } });
        return null;
      })
      .catch(function () { /* 协商失败不影响语音部分 */ });
  }

  function handleCallEvent(msg) {
    var el = callEls();
    /* ---------- 服务器转发语音（兜底）：TURN 被运营商挡住时也能通话 ----------
       16kHz 单声道 Int16 PCM，40 毫秒一帧（640 采样），base64 走长连接。
       和 App 端一模一样，两边可以互相听见。 */
    if (msg.action === 'audio') {
      if (msg.data) wsAudioPlay(msg.data);
      return;
    }
    if (msg.action === 'incoming') {
      if (call) {   // 正在通话，直接拒绝
        wsSend({ type: 'call', action: 'reject', callId: msg.callId });
        return;
      }
      call = {
        id: msg.callId, peerId: msg.peerId, peerName: msg.peerName, peerAvatar: msg.peerAvatar || '',
        role: 'callee', media: msg.media === 'video' ? 'video' : 'audio', wantsVideo: msg.media === 'video', facing: 'user', camOff: false,
        pc: callMakePc(), stream: null, timer: null, muted: false, pendingCandidates: []
      };
      if (msg.sdp) call.pc.setRemoteDescription(new RTCSessionDescription(msg.sdp)).then(callFlushCandidates).catch(function () {});
      callSetPhase('incoming', { name: msg.peerName, avatar: msg.peerAvatar });
      return;
    }
    if (!call || msg.callId !== call.id) {
      if (msg.action === 'sdp' || msg.action === 'ice') return;   // 过期信令忽略
      return;
    }
    if (msg.action === 'media') {
      var phase0 = el.card.getAttribute('data-phase') || 'active';
      if (msg.media === 'audio' && call.media === 'video') {
        call.media = 'audio';
        callSetPhase(phase0, { name: call.peerName, avatar: call.peerAvatar });
        toast('对方摄像头打不开，先用语音继续');
      } else if (msg.media === 'video' && call.media !== 'video') {
        call.media = 'video';
        call.wantsVideo = true;
        callSetPhase(phase0, { name: call.peerName, avatar: call.peerAvatar });
        toast('对方打开了摄像头');
      }
      return;
    }
    if (msg.action === 'ringing') {
      call.peerName = msg.peerName || call.peerName;
      call.peerAvatar = msg.peerAvatar || call.peerAvatar;
      return;
    }
    if (msg.action === 'accepted') {
      callSetPhase('connecting', { name: call.peerName, avatar: call.peerAvatar });
      callStartConnectTimeout();
      if (call.media !== 'video') wsAudioStart();     // 语音：立刻走服务器转发（不等 ICE）
      return;
    }
    if (msg.action === 'sdp') {
      var desc = new RTCSessionDescription(msg.sdp);
      call.pc.setRemoteDescription(desc)
        .then(function () {
          callFlushCandidates();
          // 通话中对方又开了摄像头（重新协商）：这边要回一个 answer
          if (desc.type === 'offer') {
            return call.pc.createAnswer()
              .then(function (ans) { return call.pc.setLocalDescription(ans); })
              .then(function () { return callWaitIce(call.pc); })
              .then(function () {
                if (!call || !call.pc.localDescription) return null;
                var local = call.pc.localDescription;
                wsSend({ type: 'call', action: 'sdp', callId: call.id, sdp: { type: local.type, sdp: local.sdp } });
                return null;
              });
          }
          return null;
        })
        .catch(function () { });
      return;
    }
    if (msg.action === 'ice') {
      if (msg.candidate) callAddRemoteCandidate(msg.candidate);
      return;
    }
    if (msg.action === 'end') {
      var phase = el.card.getAttribute('data-phase');
      var text = msg.reason === 'disconnected' ? '对方已断开'
        : msg.reason === 'rejected' ? '对方已拒绝'
        : (msg.reason === 'cancel' ? (phase === 'calling' ? '对方已取消' : '对方已取消')
          : (msg.reason === 'timeout' ? '对方无人接听'
            : (msg.reason === 'offline' ? '对方不在线'
              : (msg.reason === 'hangup' ? '通话已结束' : '通话结束'))));
      el.status.textContent = text;
      el.accept.hidden = true;
      callClose(1000);
      return;
    }
  }

  function startCallForChat(media) {
    var chat = state.chats.filter(function (c) { return c.id === state.activeChatId; })[0];
    if (!chat) return;
    if (chat.type === 'group') return toast('群里暂不支持通话', 'error');
    var peerId = (chat.memberIds || []).filter(function (id) { return id !== state.me.id; })[0];
    if (media !== 'video' || !navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) {
      startCall(peerId, chat.title, chat.avatar, media);
      return;
    }
    // 先看这台设备有没有摄像头：没有就直接当语音打，别等对方接了才发现打不通
    navigator.mediaDevices.enumerateDevices().then(function (list) {
      var hasCam = list.some(function (d) { return d.kind === 'videoinput'; });
      if (list.length && !hasCam) {
        if (window.confirm('这台设备没有摄像头。\n要用语音通话吗？')) startCall(peerId, chat.title, chat.avatar, 'audio');
      } else {
        startCall(peerId, chat.title, chat.avatar, 'video');
      }
    }).catch(function () { startCall(peerId, chat.title, chat.avatar, 'video'); });
  }

  function bindCallEvents() {
    $('callAcceptBtn').addEventListener('click', acceptCall);
    $('callHangupBtn').addEventListener('click', callHangup);
    $('callMuteBtn').addEventListener('click', toggleCallMute);
    $('callCamBtn').addEventListener('click', toggleCallCamera);
    $('callFlipBtn').addEventListener('click', flipCallCamera);
    $('callBtn').addEventListener('click', function () { startCallForChat('audio'); });
    $('videoCallBtn').addEventListener('click', function () { startCallForChat('video'); });
  }

  function sendMessage() {
    var input = $('composerInput');
    var text = input.value.trim();
    if (!text || !state.activeChatId) return;
    var chatId = state.activeChatId;
    var clientId = 'c' + Date.now() + Math.random().toString(16).slice(2, 6);

    var local = {
      id: clientId,
      chatId: chatId,
      senderId: state.me.id,
      kind: 'text',
      content: text,
      createdAt: new Date().toISOString(),
      recalled: false,
      pending: true
    };
    if (!state.messages[chatId]) state.messages[chatId] = [];
    state.messages[chatId].push(local);
    renderMessages();
    input.value = '';
    input.style.height = 'auto';

    var okSent = wsSend({ type: 'send', chatId: chatId, kind: 'text', content: text, clientId: clientId });
    if (!okSent) {
      api('/chats/' + encodeURIComponent(chatId) + '/messages', {
        method: 'POST',
        body: JSON.stringify({ kind: 'text', content: text, clientId: clientId })
      }).then(function (data) {
        replacePending(chatId, clientId, data.message);
      }).catch(function (err) {
        toast(err.message, 'error');
        removePending(chatId, clientId);
      });
    }
  }

  function sendImage(file) {
    if (!file || !state.activeChatId) return;
    if (file.size > 8 * 1024 * 1024) return toast('图片不能超过 8MB', 'error');
    var chatId = state.activeChatId;
    var reader = new FileReader();
    reader.onload = function () {
      api('/upload', { method: 'POST', body: JSON.stringify({ dataUrl: String(reader.result) }) })
        .then(function (data) {
          var clientId = 'c' + Date.now();
          var local = {
            id: clientId, chatId: chatId, senderId: state.me.id, kind: 'image',
            content: data.url, createdAt: new Date().toISOString(), recalled: false, pending: true
          };
          if (!state.messages[chatId]) state.messages[chatId] = [];
          state.messages[chatId].push(local);
          renderMessages();
          if (!wsSend({ type: 'send', chatId: chatId, kind: 'image', content: data.url, clientId: clientId })) {
            api('/chats/' + encodeURIComponent(chatId) + '/messages', {
              method: 'POST', body: JSON.stringify({ kind: 'image', content: data.url, clientId: clientId })
            }).then(function (r) { replacePending(chatId, clientId, r.message); })
              .catch(function (e) { toast(e.message, 'error'); removePending(chatId, clientId); });
          }
        })
        .catch(function (err) { toast(err.message, 'error'); });
    };
    reader.readAsDataURL(file);
  }

  /* -------------------------------------------------- QQ 式：表情 / 文件 / 抖动 */

  function toggleEmojiPanel() {
    var panel = $('emojiPanel');
    if (!panel.hidden) { panel.hidden = true; return; }
    if (!panel.innerHTML) {
      panel.innerHTML = EMOJIS.map(function (e) {
        return '<button type="button">' + e + '</button>';
      }).join('');
    }
    panel.hidden = false;
  }

  function insertEmoji(emoji) {
    var input = $('composerInput');
    var start = input.selectionStart == null ? input.value.length : input.selectionStart;
    var end = input.selectionEnd == null ? input.value.length : input.selectionEnd;
    input.value = input.value.slice(0, start) + emoji + input.value.slice(end);
    input.selectionStart = input.selectionEnd = start + emoji.length;
    input.focus();
  }

  function sendFile(file) {
    if (!file || !state.activeChatId) return;
    if (file.size > 12 * 1024 * 1024) return toast('文件不能超过 12MB', 'error');
    var chatId = state.activeChatId;
    var reader = new FileReader();
    reader.onload = function () {
      api('/upload', {
        method: 'POST',
        body: JSON.stringify({ dataUrl: String(reader.result), filename: file.name })
      }).then(function (d) {
        var payload = JSON.stringify({ url: d.url, name: d.name || file.name, bytes: d.bytes });
        var clientId = 'c' + Date.now();
        var local = {
          id: clientId, chatId: chatId, senderId: state.me.id, kind: 'file',
          content: payload, createdAt: new Date().toISOString(), recalled: false, pending: true
        };
        if (!state.messages[chatId]) state.messages[chatId] = [];
        state.messages[chatId].push(local);
        renderMessages();
        if (!wsSend({ type: 'send', chatId: chatId, kind: 'file', content: payload, clientId: clientId })) {
          api('/chats/' + encodeURIComponent(chatId) + '/messages', {
            method: 'POST', body: JSON.stringify({ kind: 'file', content: payload, clientId: clientId })
          }).then(function (r) { replacePending(chatId, clientId, r.message); })
            .catch(function (e) { toast(e.message, 'error'); removePending(chatId, clientId); });
        }
      }).catch(function (err) { toast(err.message, 'error'); });
    };
    reader.readAsDataURL(file);
  }

  function shakeWindow() {
    var targets = [document.querySelector('.main'), document.querySelector('.sidebar')];
    targets.forEach(function (el) {
      if (!el) return;
      el.classList.remove('shaking');
      void el.offsetWidth;
      el.classList.add('shaking');
      setTimeout(function () { el.classList.remove('shaking'); }, 700);
    });
  }

  function sendShake() {
    if (!state.activeChatId) return;
    var chat = state.chats.find(function (c) { return c.id === state.activeChatId; });
    if (!chat) return;
    if (!wsSend({ type: 'shake', chatId: state.activeChatId })) {
      return toast('连接已断开，抖动发送失败', 'error');
    }
    shakeWindow();
    toast('已向' + (chat.type === 'group' ? '群里' : '对方') + '发送窗口抖动');
  }

  function showChatInfo() {
    var chat = state.chats.find(function (c) { return c.id === state.activeChatId; });
    if (!chat) return;

    function rowFor(id) {
      var u = state.userCache[id] || { nickname: '成员' };
      return '<div class="search-result">' +
        '<div class="row-avatar js-avatar-link" data-goto-moments="' + esc(id) + '" title="看 TA 的朋友圈">' + (u.avatar ? '<img src="' + esc(u.avatar) + '" alt="">' : esc(initials(u.nickname))) + '</div>' +
        '<div class="row-main"><div class="row-top"><span class="row-name">' + esc(u.nickname) + '</span></div>' +
        '<div class="row-bottom"><span class="row-preview">' + (state.online[id] ? '在线' : '离线') + '</span></div></div></div>';
    }

    if (chat.type === 'group') {
      openModal('群成员 · ' + chat.memberIds.length + ' 人',
        chat.memberIds.map(rowFor).join(''), '');
    } else {
      var otherId = chat.memberIds.find(function (id) { return id !== state.me.id; });
      var u = state.userCache[otherId] || {};
      openModal('聊天对象',
        '<div class="search-result">' +
          '<div class="row-avatar js-avatar-link" data-goto-moments="' + esc(otherId) + '" title="看 TA 的朋友圈">' + (u.avatar ? '<img src="' + esc(u.avatar) + '" alt="">' : esc(initials(u.nickname || '?'))) + '</div>' +
          '<div class="row-main"><div class="row-top"><span class="row-name">' + esc(u.nickname || '未知') + '</span></div>' +
          '<div class="row-bottom"><span class="row-preview">@' + esc(u.username || '') +
          ' · ' + (state.online[otherId] ? '在线' : '离线') + '</span></div></div></div>',
        '');
    }
  }

  function replacePending(chatId, clientId, message) {
    var list = state.messages[chatId] || [];
    var idx = list.findIndex(function (m) { return m.id === clientId; });
    if (idx !== -1) list.splice(idx, 1);
    if (!list.some(function (m) { return m.id === message.id; })) list.push(message);
    renderMessages();
  }

  function removePending(chatId, clientId) {
    var list = state.messages[chatId] || [];
    state.messages[chatId] = list.filter(function (m) { return m.id !== clientId; });
    renderMessages();
  }

  function recall(messageId) {
    var chatId = state.activeChatId;
    api('/messages/' + encodeURIComponent(messageId) + '/recall', {
      method: 'POST', body: JSON.stringify({ chatId: chatId })
    }).then(function () {
      var list = state.messages[chatId] || [];
      list.forEach(function (m) { if (m.id === messageId) m.recalled = true; });
      renderMessages();
    }).catch(function (err) { toast(err.message, 'error'); });
  }

  /* --------------------------------------------------------------- 弹窗 */

  function openModal(title, bodyHtml, footHtml) {
    var maskReset = $('modalMask'), cardReset = $('modalCard');
    // 朋友圈在画中画里时，弹窗也要弹在画中画那个窗口里
    var doc = activeDoc();
    if (maskReset && maskReset.parentNode !== doc.body) doc.body.appendChild(maskReset);
    if (maskReset) maskReset.classList.remove('is-card');
    if (cardReset) { cardReset.style.position = ''; cardReset.style.left = ''; cardReset.style.top = ''; cardReset.style.margin = ''; }
    $('modalTitle').textContent = title;
    $('modalBody').innerHTML = bodyHtml;
    $('modalFoot').innerHTML = footHtml || '';
    // 名片那种「只有一个发消息按钮」的底部，让它居中
    $('modalFoot').classList.toggle('is-center', /card-actions|card-msg-btn/.test(footHtml || ''));
    $('modalMask').hidden = false;
  }

  function closeModal() {
    $('modalMask').hidden = true;
    $('modalBody').innerHTML = '';
    $('modalFoot').innerHTML = '';
  }

  function modalAddFriend() {
    openModal('添加好友',
      '<label class="field"><span class="field-label">对方的用户名</span><input id="findUser" placeholder="输入完整用户名" autocomplete="off"></label>' +
      '<div id="findResult"></div>',
      '<button class="btn-primary" id="doFind">搜索</button>');
    var input = $('findUser');
    input.focus();
    $('doFind').addEventListener('click', doFindUser);
    input.addEventListener('keydown', function (e) { if (e.key === 'Enter') doFindUser(); });
  }

  function doFindUser() {
    var q = $('findUser').value.trim();
    if (!q) return;
    api('/users?q=' + encodeURIComponent(q)).then(function (data) {
      var list = data.users || [];
      if (!list.length) {
        $('findResult').innerHTML = '<p class="auth-hint">没找到用户，确认用户名是否正确（区分大小写不敏感）。</p>';
        return;
      }
      $('findResult').innerHTML = list.map(function (u) {
        var action = u.relation === 'friend' ? '<span class="auth-hint">已是好友</span>'
          : (u.relation === 'requested' ? '<span class="auth-hint">已发送</span>'
            : '<button class="tiny-btn" data-add="' + esc(u.username) + '">加好友</button>');
        return '<div class="search-result"><div class="row-avatar js-avatar-link" data-goto-moments="' + esc(u.id) + '" data-moment-name="' + esc(u.nickname) + '" data-moment-avatar="' + esc(u.avatar || '') + '" title="看 TA 的朋友圈">' +
          (u.avatar ? '<img src="' + esc(u.avatar) + '" alt="">' : esc(initials(u.nickname))) + '</div>' +
          '<div class="row-main"><div class="row-top"><span class="row-name">' + esc(u.nickname) + '</span></div>' +
          '<div class="row-bottom"><span class="row-preview">@' + esc(u.username) + '</span></div></div>' +
          action + '</div>';
      }).join('');
    }).catch(function (err) { toast(err.message, 'error'); });
  }

  /* -------------------------------------------------------- 面对面建群 */

  function faceRandomCode() {
    return String(Math.floor(1000 + Math.random() * 9000));
  }

  function renderFaceCodeBox() {
    var input = $('faceCode');
    if (!input) return;
    var v = input.value.replace(/\D/g, '').slice(0, 4);
    if (v !== input.value) input.value = v;
    var hint = $('faceCodeHint');
    if (hint) hint.textContent = v.length === 4 ? '可以进去了' : '还需要 ' + (4 - v.length) + ' 位数字';
    var btn = $('faceJoinBtn');
    if (btn) btn.disabled = v.length !== 4;
  }

  /* ------------------------------------------------ 侧栏 ＋ 下拉菜单 */

  function openNewChatMenu() {
    var menu = $('newChatMenu');
    if (!menu) return;
    menu.hidden = false;
    $('newChatBtn').classList.add('is-open');
    $('newChatBtn').setAttribute('aria-expanded', 'true');
  }

  function closeNewChatMenu() {
    var menu = $('newChatMenu');
    if (!menu || menu.hidden) return;
    menu.hidden = true;
    $('newChatBtn').classList.remove('is-open');
    $('newChatBtn').setAttribute('aria-expanded', 'false');
  }

  function toggleNewChatMenu() {
    var menu = $('newChatMenu');
    if (!menu) return;
    if (menu.hidden) openNewChatMenu(); else closeNewChatMenu();
  }

  function runNewChatAction(kind) {
    if (kind === 'friend') { switchPanel('contacts'); modalAddFriend(); return; }
    if (kind === 'group') { modalCreateGroup(); return; }
    if (kind === 'face') { modalFaceToFace(); return; }
    switchPanel('contacts');
  }

  function modalFaceToFace() {
    openModal('面对面建群',
      '<p class="face-tip">和身边的朋友<b>输入同样的 4 位数字</b>，就会进到同一个群聊里。</p>' +
      '<input class="face-code-input" id="faceCode" inputmode="numeric" autocomplete="off" maxlength="4" placeholder="····">' +
      '<p class="face-code-hint" id="faceCodeHint">还需要 4 位数字</p>' +
      '<p class="auth-hint">数字 3 分钟内有效，每有人进来就重新计时；过期后同样的数字会开一个新群。</p>',
      '<button class="btn-ghost" id="faceRandomBtn">随机一个数字</button>' +
      '<button class="btn-primary" id="faceJoinBtn" disabled>进入群聊</button>');

    var input = $('faceCode');
    if (input) {
      input.focus();
      input.addEventListener('input', renderFaceCodeBox);
      input.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') { e.preventDefault(); joinFaceGroup(); }
      });
    }
    $('faceRandomBtn').addEventListener('click', function () {
      input.value = faceRandomCode();
      renderFaceCodeBox();
      input.focus();
    });
    $('faceJoinBtn').addEventListener('click', joinFaceGroup);
    renderFaceCodeBox();
  }

  function joinFaceGroup() {
    var input = $('faceCode');
    if (!input) return;
    var code = input.value.replace(/\D/g, '');
    if (code.length !== 4) return toast('请输入 4 位数字', 'error');
    var btn = $('faceJoinBtn');
    btn.disabled = true;
    api('/chats/face', { method: 'POST', body: JSON.stringify({ code: code }) })
      .then(function (data) {
        closeModal();
        loadChats().then(function () { openChat(data.chat.id); });
        toast(data.created
          ? '已创建群聊「' + data.chat.title + '」，数字 ' + code + ' 三分钟内有效'
          : '已进入群聊「' + data.chat.title + '」，现在 ' + data.memberCount + ' 个人');
      })
      .catch(function (err) { toast(err.message, 'error'); })
      .then(function () { if (btn) btn.disabled = false; });
  }

  function modalCreateGroup() {
    if (!state.friends.length) return toast('先加几个好友才能建群', 'error');
    var rows = state.friends.map(function (f) {
      return '<label class="pick-row"><input type="checkbox" value="' + esc(f.id) + '">' +
        '<div class="row-avatar" data-uid="' + esc(f.id) + '">' + (f.avatar ? '<img src="' + esc(f.avatar) + '" alt="">' : esc(initials(f.nickname))) + '</div>' +
        '<span>' + esc(f.nickname) + '</span></label>';
    }).join('');
    openModal('发起群聊',
      '<label class="field"><span class="field-label">群名称</span><input id="groupName" placeholder="例如：项目讨论组"></label>' +
      '<div class="list-title">选择成员</div>' + rows,
      '<button class="btn-primary" id="doCreateGroup">创建</button>');
    $('doCreateGroup').addEventListener('click', function () {
      var name = $('groupName').value.trim();
      if (!name) return toast('请填写群名称', 'error');
      var ids = Array.prototype.slice.call(document.querySelectorAll('.pick-row input:checked'))
        .map(function (i) { return i.value; });
      if (!ids.length) return toast('至少选一个好友', 'error');
      api('/chats/group', { method: 'POST', body: JSON.stringify({ name: name, memberIds: ids }) })
        .then(function (data) {
          closeModal();
          upsertChat(data.chat);
          openChat(data.chat.id);
          toast('群聊已创建');
        })
        .catch(function (err) { toast(err.message, 'error'); });
    });
  }

  /* ------------------------------------------------------------ 安全中心 */
  /* ---------------------------------------------------------- 手机访问 */
  function modalPhoneAccess() {
    var closeFoot = '<button class="btn-ghost" id="phoneClose">关闭</button>';
    openModal('手机访问', '<div class="sec-loading">正在读取局域网地址…</div>', closeFoot);
    if ($('phoneClose')) $('phoneClose').onclick = closeModal;
    api('/lan').then(function (d) {
      var urls = (d.urls || []).filter(function (u) { return u.ip && u.ip.indexOf('169.254.') !== 0; });
      if (!urls.length) {
        openModal('手机访问', '<p class="auth-hint">没有找到局域网地址，先确认电脑连着 Wi-Fi。</p>', closeFoot);
        if ($('phoneClose')) $('phoneClose').onclick = closeModal;
        return;
      }
      var main = urls[0];
      var body =
        '<div class="phone-access">' +
          '<div class="pa-url" id="paUrl">' + esc(main.url) + '</div>' +
          '<button class="btn-primary sec-wide" id="paCopy">复制地址</button>' +
          '<a class="btn-ghost sec-wide" href="/m.html" target="_blank" rel="noopener" style="display:block;text-align:center;text-decoration:none;line-height:38px;">在电脑上预览手机版</a>' +
          '<ol class="auth-steps pa-steps">' +
            '<li>手机连<b>和电脑同一个 Wi-Fi</b>（不要用流量）</li>' +
            '<li>手机浏览器打开上面这个地址（要带 http://）</li>' +
            '<li>用你的账号密码登录，就是手机版界面</li>' +
          '</ol>' +
          (urls.length > 1
            ? '<div class="pa-others">其他网卡地址：' + urls.slice(1).map(function (u) { return '<code>' + esc(u.url) + '</code>'; }).join(' ') + '</div>'
            : '') +
          '<p class="sec-note">打不开的先试这个：在手机浏览器打开 <code>http://' + esc((main.ip.split('.').slice(0, 3).join('.')) ) + '.1</code>（路由器地址）。能打开说明同一个局域网；打不开说明手机和电脑不在同一个网络，改用手机开热点、电脑连手机热点再访问。</p>' +
        '</div>';
      openModal('手机访问', body, closeFoot);
      $('phoneClose').onclick = closeModal;
      $('paCopy').onclick = function () {
        var text = main.url;
        var done = function () { toast('地址已复制'); };
        try {
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(done).catch(function () { fallback(); });
          } else fallback();
        } catch (e) { fallback(); }
        function fallback() {
          try {
            var ta = document.createElement('textarea');
            ta.value = text; document.body.appendChild(ta); ta.select();
            document.execCommand('copy'); document.body.removeChild(ta); done();
          } catch (e2) { toast('复制失败，手动输入吧：' + text, 'error'); }
        }
      };
    }).catch(function (err) {
      openModal('手机访问', '<p class="auth-hint">' + esc(err.message) + '</p>', closeFoot);
      if ($('phoneClose')) $('phoneClose').onclick = closeModal;
    });
  }

  function secTimeText(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '—';
    var now = new Date();
    var p2 = function (n) { return (n < 10 ? '0' : '') + n; };
    var hm = p2(d.getHours()) + ':' + p2(d.getMinutes());
    if (d.toDateString() === now.toDateString()) return '今天 ' + hm;
    var y = new Date(now.getTime() - 86400000);
    if (d.toDateString() === y.toDateString()) return '昨天 ' + hm;
    if (d.getFullYear() === now.getFullYear()) return (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + hm;
    return d.getFullYear() + '年' + (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + hm;
  }

  function modalSecurity() {
    var closeFoot = '<button class="btn-ghost" id="secClose">关闭</button>';
    openModal('安全中心', '<div class="sec-loading">正在读取安全信息…</div>', closeFoot);
    if ($('secClose')) $('secClose').onclick = closeModal;

    api('/me/security').then(function (d) {
      var logins = d.logins || [];
      var score = d.score || 0;
      var tone = score >= 80 ? 'is-good' : (score >= 60 ? 'is-mid' : 'is-low');
      var title = score >= 80 ? '安全状况良好' : (score >= 60 ? '建议再加固一下' : '账号风险偏高');
      var tips = [];
      tips.push(d.changedPassword ? '已修改过密码' : '建议修改一次初始密码');
      tips.push(d.hasPhone ? '已绑定手机号' : '可绑定手机号');
      tips.push('常用设备 ' + (d.deviceCount || 0) + ' 台');

      var loginHtml = logins.length ? logins.map(function (l, i) {
        var kindTxt = l.kind === 'password' ? '修改密码'
          : (l.kind === 'logout-others' ? '退出其他设备'
            : (l.kind === 'register' ? '注册' : '登录'));
        return '<div class="sec-login">' +
          '<span class="sec-login-ico' + (i === 0 ? ' is-now' : '') + '"></span>' +
          '<div class="sec-login-main">' +
            '<div class="sec-login-dev">' + esc(l.device) + (i === 0 ? '<i class="sec-now">最近</i>' : '') + '</div>' +
            '<div class="sec-login-sub">' + esc(secTimeText(l.time)) + ' · ' + esc(l.ip || '本机') + ' · ' + esc(kindTxt) + '</div>' +
          '</div></div>';
      }).join('') : '<div class="sec-empty">还没有登录记录</div>';

      var body =
        '<div class="sec-head ' + tone + '">' +
          '<div class="sec-ring"><b>' + score + '</b><i>分</i></div>' +
          '<div class="sec-head-txt">' +
            '<div class="sec-title">' + esc(title) + '</div>' +
            '<div class="sec-sub">' + esc(tips.join(' · ')) + '</div>' +
          '</div>' +
        '</div>' +
        '<div class="sec-block">' +
          '<div class="sec-block-title">登录记录</div>' +
          '<div class="sec-logins">' + loginHtml + '</div>' +
          '<button class="btn-ghost sec-wide" id="secLogoutOthers">退出其他所有设备</button>' +
          '<p class="sec-note">点完其他设备会被强制下线，本机不受影响。</p>' +
        '</div>' +
        '<div class="sec-block">' +
          '<div class="sec-block-title">修改密码</div>' +
          '<div class="sec-form">' +
            '<input type="password" id="secOld" placeholder="当前密码" autocomplete="current-password">' +
            '<input type="password" id="secNew" placeholder="新密码（至少 6 位）" autocomplete="new-password">' +
            '<input type="password" id="secNew2" placeholder="确认新密码" autocomplete="new-password">' +
          '</div>' +
          '<p class="sec-error" id="secErr" hidden></p>' +
          '<button class="btn-primary sec-wide" id="secSave">保存新密码</button>' +
          '<p class="sec-note">' + (d.passwordUpdatedAt ? '上次修改：' + esc(secTimeText(d.passwordUpdatedAt)) : '这个账号还没有改过密码') + '</p>' +
        '</div>';

      openModal('安全中心', body, closeFoot);
      $('secClose').onclick = closeModal;

      $('secLogoutOthers').onclick = function () {
        if (!window.confirm('确定让其他所有设备退出登录吗？')) return;
        var btn = this;
        btn.disabled = true;
        api('/me/logout-others', { method: 'POST' })
          .then(function () { toast('已退出其他所有设备'); modalSecurity(); })
          .catch(function (err) { toast(err.message, 'error'); })
          .then(function () { btn.disabled = false; });
      };

      $('secSave').onclick = function () {
        var err = $('secErr');
        var bad = function (t) { err.textContent = t; err.hidden = false; };
        err.hidden = true;
        var oldP = $('secOld').value;
        var n1 = $('secNew').value;
        var n2 = $('secNew2').value;
        if (!oldP) return bad('请输入当前密码');
        if (n1.length < 6) return bad('新密码至少 6 位');
        if (n1 !== n2) return bad('两次输入的新密码不一致');
        if (n1 === oldP) return bad('新密码不能和当前密码一样');
        var btn = this;
        btn.disabled = true;
        api('/me/password', { method: 'POST', body: JSON.stringify({ currentPassword: oldP, newPassword: n1 }) })
          .then(function () {
            toast('密码已修改，其他设备需要重新登录');
            modalSecurity();
          })
          .catch(function (e2) { bad(e2.message); })
          .then(function () { btn.disabled = false; });
      };
    }).catch(function (err) {
      openModal('安全中心', '<p class="auth-hint">' + esc(err.message) + '</p>', closeFoot);
      if ($('secClose')) $('secClose').onclick = closeModal;
    });
  }

  function modalProfile() {
    var me = state.me;
    var draftAvatar = me.avatar || '';
    var uploadTask = null;

    function faceHtml(avatar, nickname) {
      return avatar
        ? '<img src="' + esc(avatar) + '" alt="">'
        : esc(initials(nickname || me.username));
    }

    openModal('我的资料',
      '<div class="profile-head">' +
        '<button type="button" class="profile-avatar" id="profileAvatarBtn" title="更换头像">' +
          '<span class="pa-face" id="paFace">' + faceHtml(draftAvatar, me.nickname) + '</span>' +
          '<span class="pa-mask">' + "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.7\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M4 8.5h3l1.4-2.2h7.2L17 8.5h3A1.5 1.5 0 0 1 21.5 10v7A1.5 1.5 0 0 1 20 18.5H4A1.5 1.5 0 0 1 2.5 17v-7A1.5 1.5 0 0 1 4 8.5z\"/><circle cx=\"12\" cy=\"13\" r=\"3.2\"/></svg>" + '<span>更换头像</span></span>' +
        '</button>' +
        '<div class="profile-name" id="profileName">' + esc(me.nickname) + '</div>' +
        '<div class="profile-username">@' + esc(me.username) + ' · 用户名不可修改</div>' +
      '</div>' +
      '<div class="profile-fields">' +
        '<label class="profile-field">' +
          '<span class="profile-label">昵称</span>' +
          '<input id="pNickname" maxlength="24" placeholder="给自己取个名字" value="' + esc(me.nickname) + '">' +
          '<span class="profile-count" id="countNickname"></span>' +
        '</label>' +
        '<label class="profile-field">' +
          '<span class="profile-label">地区</span>' +
          '<input id="pRegion" maxlength="40" placeholder="例如：中国香港 元朗区" value="' + esc(me.region || '') + '">' +
          '<span class="profile-count" id="countRegion"></span>' +
        '</label>' +
        '<div class="profile-field"><span class="profile-label">性别</span>' +
          '<div class="gender-picker is-profile" id="pGender">' +
            '<button type="button" class="gender-btn' + (me.gender === 'male' ? ' is-active' : '') + '" data-gender="male">男</button>' +
            '<button type="button" class="gender-btn' + (me.gender === 'female' ? ' is-active' : '') + '" data-gender="female">女</button>' +
          '</div>' +
        '</div>' +
        '<label class="profile-field">' +
          '<span class="profile-label">个性签名</span>' +
          '<input id="pBio" maxlength="60" placeholder="写一句话介绍自己" value="' + esc(me.bio || '') + '">' +
          '<span class="profile-count" id="countBio"></span>' +
        '</label>' +
      '</div>' +
      '<input type="file" id="pAvatarFile" accept="image/*" hidden>',
      '<button class="btn-primary" id="doSaveProfile">保存资料</button>');

    function refreshPreview() {
      $('countNickname').textContent = $('pNickname').value.length + ' / 24';
      $('countBio').textContent = $('pBio').value.length + ' / 60';
      if ($('countRegion')) $('countRegion').textContent = $('pRegion').value.length + ' / 40';
      $('profileName').textContent = $('pNickname').value.trim() || me.username;
    }
    refreshPreview();
    // 性别：以后台/注册填的为准，这里可以改
    var draftGender = (me.gender === 'male' || me.gender === 'female') ? me.gender : '';
    if ($('pGender')) {
      $('pGender').addEventListener('click', function (e) {
        var b = e.target.closest('[data-gender]');
        if (!b) return;
        draftGender = b.getAttribute('data-gender');
        document.querySelectorAll('#pGender .gender-btn').forEach(function (x) {
          x.classList.toggle('is-active', x === b);
        });
      });
    }
    $('pNickname').addEventListener('input', refreshPreview);
    $('pBio').addEventListener('input', refreshPreview);

    $('profileAvatarBtn').addEventListener('click', function () { $('pAvatarFile').click(); });

    $('pAvatarFile').addEventListener('change', function (ev) {
      var file = ev.target.files && ev.target.files[0];
      if (!file) return;
      if (file.size > 8 * 1024 * 1024) { toast('图片不能超过 8MB', 'error'); return; }
      var reader = new FileReader();
      uploadTask = new Promise(function (resolve) {
        reader.onload = function () {
          api('/upload', {
            method: 'POST',
            body: JSON.stringify({ dataUrl: String(reader.result), filename: file.name })
          }).then(function (d) {
            draftAvatar = d.url;
            $('paFace').innerHTML = faceHtml(draftAvatar, $('pNickname').value);
            toast('头像已上传，点「保存资料」生效');
            resolve();
          }).catch(function (err) {
            toast(err.message, 'error');
            resolve();
          });
        };
        reader.readAsDataURL(file);
      });
      ev.target.value = '';
    });

    $('doSaveProfile').addEventListener('click', function () {
      var btn = this;
      btn.disabled = true;
      Promise.resolve(uploadTask).catch(function () {}).then(function () {
        return api('/me', {
          method: 'PATCH',
          body: JSON.stringify({
            nickname: $('pNickname').value.trim(),
            region: $('pRegion') ? $('pRegion').value.trim() : '',
            gender: draftGender,
            bio: $('pBio').value.trim(),
            avatar: draftAvatar
          })
        });
      }).then(function (data) {
        state.me = data.user;
        renderMe();
        closeModal();
        toast('资料已更新');
      }).catch(function (err) { toast(err.message, 'error'); })
        .then(function () { btn.disabled = false; });
    });
  }

  /* --------------------------------------------------------------- 交互 */

  function switchPanel(panel) {
    // 朋友圈在画中画浮窗里时，主窗口不要切到「朋友圈」（否则主窗口会空掉一块）
    if (panel === 'moments' && momentsInPip()) {
      document.querySelectorAll('.side-tab').forEach(function (t) {
        t.classList.toggle('is-active', t.getAttribute('data-panel') === state.panel);
      });
      return;
    }
    state.panel = panel;
    var appEl = document.querySelector('.app');
    if (appEl) appEl.setAttribute('data-panel', panel);   // 手机版靠它决定显示哪个页面
    state.listFilter = panel === 'groups' ? 'group' : 'all';
    document.querySelectorAll('.side-tab').forEach(function (t) {
      t.classList.toggle('is-active', t.getAttribute('data-panel') === panel);
    });
    var showList = panel === 'chats' || panel === 'groups';
    $('chatList').hidden = !showList;
    $('contactsPanel').hidden = panel !== 'contacts';
    if (panel === 'contacts') renderFriends();
    if (showList) renderChats();

    var app = document.querySelector('.app');
    if (panel === 'moments') {
      app.classList.remove('show-chat');
      $('emptyChat').hidden = true;
      $('chatPane').hidden = true;
      $('momentsPane').hidden = false;
      applyMomentsHeader();
      loadMoments(!state.momentUser).catch(function (err) { toast(err.message, 'error'); });
    } else {
      $('momentsPane').hidden = true;
      if (state.activeChatId) {
        $('emptyChat').hidden = true;
        $('chatPane').hidden = false;
      } else {
        $('emptyChat').hidden = false;
        $('chatPane').hidden = true;
      }
    }
  }

  function setupEvents() {
    document.querySelectorAll('.auth-tab').forEach(function (tab) {
      tab.addEventListener('click', function () { setAuthMode(tab.getAttribute('data-auth-tab')); });
    });
    $('authForm').addEventListener('submit', submitAuth);
    $('authFoot').addEventListener('click', function (e) {
      var link = e.target.closest('[data-auth-tab]');
      if (link) setAuthMode(link.getAttribute('data-auth-tab'));
    });
    if ($('authRemember')) $('authRemember').checked = true;
    if ($('authAuto')) $('authAuto').checked = autoLoginEnabled();
    if ($('authForgot')) $('authForgot').addEventListener('click', modalForgotPassword);
    if ($('authCaptchaImg')) $('authCaptchaImg').addEventListener('click', loadCaptcha);
    var agreeRow = $('authAgreeRow');
    if (agreeRow) {
      agreeRow.addEventListener('click', function (e) {
        var doc = e.target.closest('[data-doc]');
        if (doc) { e.preventDefault(); modalDoc(doc.getAttribute('data-doc')); }
      });
    }
    if ($('authPairOpen')) $('authPairOpen').addEventListener('click', openPairPanel);
    if ($('authPairBack')) $('authPairBack').addEventListener('click', closePairPanel);
    if ($('authPairCopy')) {
      $('authPairCopy').addEventListener('click', function () {
        var url = $('authPairUrl').textContent;
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(url).then(function () { toast('链接已复制'); }, function () { toast(url); });
        } else { toast(url); }
      });
    }
    if ($('authUsername')) {
      $('authUsername').addEventListener('change', applyRememberedPassword);
    }
    var eye = $('authEyeBtn');
    // 注册页的性别选择（以后台注册为准）
    if ($('authGender')) {
      $('authGender').addEventListener('click', function (e) {
        var b = e.target.closest('[data-gender]');
        if (!b) return;
        state.authGender = b.getAttribute('data-gender');
        document.querySelectorAll('#authGender .gender-btn').forEach(function (x) {
          x.classList.toggle('is-active', x === b);
        });
      });
    }
    if (eye) {
      eye.addEventListener('click', function () {
        var input = $('authPassword');
        var show = input.type === 'password';
        input.type = show ? 'text' : 'password';
        eye.classList.toggle('is-on', show);
        eye.title = show ? '隐藏密码' : '显示密码';
        input.focus();
      });
    }
    $('authAccounts').addEventListener('click', function (e) {
      var other = e.target.closest('#authOtherBtn');
      if (other) { clearPickedAccount(); return; }
      var card = e.target.closest('[data-account]');
      if (card) pickAccount(card.getAttribute('data-account'));
    });

    setupAccountMenu();

    $('sideSearch').addEventListener('input', function () {
      // 现在在哪个页面就搜哪个：联系人页面搜好友，会话页面搜会话
      var cp = $('contactsPanel');
      if (cp && !cp.hidden) renderFriends(); else renderChats();
    });
    $('newChatBtn').addEventListener('click', function (e) {
      e.stopPropagation();
      toggleNewChatMenu();
    });
    $('newChatMenu').addEventListener('click', function (e) {
      var item = e.target.closest('[data-new]');
      if (!item) return;
      closeNewChatMenu();
      runNewChatAction(item.getAttribute('data-new'));
    });
    document.addEventListener('click', function (e) {
      if (!e.target.closest('.side-plus-wrap')) closeNewChatMenu();
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') closeNewChatMenu();
    });
    document.querySelectorAll('.side-tab').forEach(function (t) {
      t.addEventListener('click', function () {
        var panel = t.getAttribute('data-panel');
        if (panel === 'moments') {
          state.momentUser = null;
          state.momentUserInfo = null;
          // 支持画中画就用浮窗打开（再点一次关掉），不支持就还是原来的内嵌页面
          if (openMomentsPip()) return;
        }
        switchPanel(panel);
      });
    });

    $('chatList').addEventListener('click', function (e) {
      var more = e.target.closest('[data-row-menu]');
      if (more) {
        e.stopPropagation();
        var mr = more.getBoundingClientRect();
        openCtxMenu(more.getAttribute('data-row-menu'), Math.round(mr.right - 6), Math.round(mr.bottom + 6));
        return;
      }
      if (momentsLinkFrom(e)) return;
      var row = e.target.closest('[data-chat]');
      if (row) openChat(row.getAttribute('data-chat'));
    });
    $('chatList').addEventListener('contextmenu', function (e) {
      var row = e.target.closest('[data-chat]');
      if (!row) return;
      e.preventDefault();
      openCtxMenu(row.getAttribute('data-chat'), e.clientX, e.clientY);
    });
    $('ctxMenu').addEventListener('click', function (e) {
      var item = e.target.closest('[data-ctx]');
      if (item) ctxAction(item.getAttribute('data-ctx'));
    });
    document.addEventListener('click', function (e) {
      if (!e.target.closest('#ctxMenu') && !e.target.closest('[data-row-menu]')) closeCtxMenu();
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') closeCtxMenu();
    });
    window.addEventListener('blur', closeCtxMenu);

    $('friendList').addEventListener('click', function (e) {
      if (momentsLinkFrom(e)) return;
      var row = e.target.closest('[data-open-user]');
      if (row) openDirectWith(row.getAttribute('data-open-user'));
    });

    $('requestList').addEventListener('click', function (e) {
      var accept = e.target.closest('[data-accept]');
      var reject = e.target.closest('[data-reject]');
      if (!accept && !reject) return;
      var id = (accept || reject).getAttribute(accept ? 'data-accept' : 'data-reject');
      api('/friends/respond', { method: 'POST', body: JSON.stringify({ requestId: id, accept: !!accept }) })
        .then(function () { loadContacts(); toast(accept ? '已添加好友' : '已拒绝'); })
        .catch(function (err) { toast(err.message, 'error'); });
    });

    // 这三个入口统一收进侧栏 ＋ 下拉菜单里了
    $('meAvatarBtn').addEventListener('click', function () {
    if (state.me) openProfileCard(state.me.id, state.me.nickname, state.me.avatar);
  });
    bindCallEvents();

    $('chatAvatar').addEventListener('click', function (e) {
      if (momentsLinkFrom(e)) return;
    });

    $('momentsBack').addEventListener('click', closeUserMoments);

    $('publishBtn').addEventListener('click', function (e) {
      e.stopPropagation();
      toggleFabMenu();
    });
    $('fabMenu').addEventListener('click', function (e) {
      var b = e.target.closest('[data-fab]');
      if (!b) return;
      e.stopPropagation();
      closeFabMenu();
      if (b.getAttribute('data-fab') === 'cover') openCoverEditor();
      else openCompose();
    });
    document.addEventListener('click', function (e) {
      var m = $('fabMenu');
      if (!m || m.hidden) return;
      if (e.target.closest && (e.target.closest('#fabMenu') || e.target.closest('#publishBtn'))) return;
      closeFabMenu();
    });
    $('coverBtn').addEventListener('click', openCoverEditor);
    // 朋友圈图片：全局接管（不管有没有点过名片都能用），直接开独立窗口
    $('momentList').addEventListener('click', function (e) {
      var im = e.target && e.target.closest ? e.target.closest('.moment-images img') : null;
      if (!im) return;
      e.preventDefault();
      e.stopPropagation();
      var box = im.closest('.moment-images');
      var all = box ? Array.prototype.map.call(box.querySelectorAll('img'), function (x) { return x.src; }) : [im.src];
      openPhotoView(all, all.indexOf(im.src));
    }, true);
    document.addEventListener('click', function (e) {
      var im = e.target && e.target.closest ? e.target.closest('.moment-images img') : null;
      if (!im) return;
      e.preventDefault();
      e.stopPropagation();
      var box = im.closest('.moment-images');
      var all = box ? Array.prototype.map.call(box.querySelectorAll('img'), function (x) { return x.src; }) : [im.src];
      openPhotoView(all, all.indexOf(im.src));
    }, true);
    $('momentList').addEventListener('click', function (e) {
      if (momentsLinkFrom(e)) return;
      var like = e.target.closest('[data-like]');
      var comment = e.target.closest('[data-comment]');
      var send = e.target.closest('[data-comment-send]');
      var del = e.target.closest('[data-del-moment]');
      var img = e.target.closest('[data-preview]');
      if (like) return toggleLike(like.getAttribute('data-like'));
      if (comment) {
        state.commenting = state.commenting === comment.getAttribute('data-comment')
          ? null : comment.getAttribute('data-comment');
        renderMoments();
        return undefined;
      }
      if (send) return submitComment(send.getAttribute('data-comment-send'));
      if (del) return deleteMoment(del.getAttribute('data-del-moment'));
      if (img) return openPhotoView([img.getAttribute('data-preview')], 0);
      return undefined;
    });
    $('momentList').addEventListener('keydown', function (e) {
      var input = e.target.closest('[data-comment-input]');
      if (input && e.key === 'Enter') {
        e.preventDefault();
        submitComment(input.getAttribute('data-comment-input'));
      }
    });

    $('sendBtn').addEventListener('click', sendMessage);
    $('composerInput').addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        sendMessage();
      }
    });
    $('composerInput').addEventListener('input', function () {
      this.style.height = 'auto';
      this.style.height = Math.min(this.scrollHeight, 140) + 'px';
      if (state.activeChatId) wsSend({ type: 'typing', chatId: state.activeChatId });
    });

    $('imageBtn').addEventListener('click', function () { $('imageInput').click(); });
    $('voiceBtn').addEventListener('click', function () { setVoiceMode(!voiceMode); });
    bindVoiceHold();
    $('voiceFileBtn').addEventListener('click', function () { $('voiceFileInput').click(); });
    $('voiceFileInput').addEventListener('change', function (e) {
      var f = e.target.files && e.target.files[0];
      e.target.value = '';
      sendVoiceFile(f);
    });
    $('imageInput').addEventListener('change', function (e) {
      var file = e.target.files && e.target.files[0];
      if (file) sendImage(file);
      e.target.value = '';
    });

    $('emojiBtn').addEventListener('click', function (e) {
      e.stopPropagation();
      toggleEmojiPanel();
    });
    $('emojiPanel').addEventListener('click', function (e) {
      var btn = e.target.closest('button');
      if (btn) insertEmoji(btn.textContent);
    });
    document.addEventListener('click', function (e) {
      if (!e.target.closest('.composer')) $('emojiPanel').hidden = true;
    });

    $('fileBtn').addEventListener('click', function () { $('fileInput').click(); });
    $('fileInput').addEventListener('change', function (e) {
      var file = e.target.files && e.target.files[0];
      if (file) sendFile(file);
      e.target.value = '';
    });

    $('shakeBtn').addEventListener('click', sendShake);
    $('headGroupBtn').addEventListener('click', modalCreateGroup);
    $('headMoreBtn').addEventListener('click', showChatInfo);

    $('messages').addEventListener('click', function (e) {
      var voiceBox = e.target.closest('[data-voice]');
      if (voiceBox) { toggleVoice(voiceBox); return; }
      var tCard = e.target.closest('[data-transfer]');
      if (tCard) { onTransferCardClick(tCard); return; }
      if (momentsLinkFrom(e)) return;
      var recallBtn = e.target.closest('[data-recall]');
      if (recallBtn) return recall(recallBtn.getAttribute('data-recall'));
      var img = e.target.closest('[data-preview]');
      if (img) openPhotoView([img.getAttribute('data-preview')], 0);
    });

    $('backBtn').addEventListener('click', function () {
      document.querySelector('.app').classList.remove('show-chat');
    });

    $('modalClose').addEventListener('click', closeModal);
    $('modalMask').addEventListener('click', function (e) {
      if (e.target === $('modalMask')) closeModal();
    });
    $('modalBody').addEventListener('click', function (e) {
      if (momentsLinkFrom(e)) return;
      var addBtn = e.target.closest('[data-add]');
      if (!addBtn) return;
      api('/friends/request', { method: 'POST', body: JSON.stringify({ username: addBtn.getAttribute('data-add') }) })
        .then(function () { addBtn.outerHTML = '<span class="auth-hint">已发送</span>'; toast('好友请求已发送'); })
        .catch(function (err) { toast(err.message, 'error'); });
    });

    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') closeModal();
    });

    setInterval(function () {
      wsSend({ type: 'ping' });
      updateTyping();
    }, 20000);
  }

  /* --------------------------------------------------------------- 启动 */

  function showApp() {
    $('authScreen').hidden = true;
    $('appScreen').hidden = false;
    renderMe();
  }

  /* ------------------------------------------------ 界面自动更新检测 */

  // 前端文件一改，版本号就变；开着页面的人会自动刷到新界面，不用手动清缓存
  function startVersionWatch() {
    var known = null;

    function refreshVersionLabel() {
      var el = $('meVersionText');
      if (!el) return;
      var mine = state.loadedVersion || '(未知)';
      api('/version').then(function (d) {
        var server = (d && d.version) || '';
        if (server && server !== state.loadedVersion) {
          el.innerHTML = '版本 ' + esc(mine.slice(0, 8)) + ' · <b>有新版本</b>';
        } else {
          el.textContent = '版本 ' + mine.slice(0, 8) + ' · 已是最新';
        }
      }).catch(function () { el.textContent = '版本 ' + String(mine).slice(0, 8); });
    }

    function composerHasDraft() {
      var el = $('composerInput');
      return !!(el && String(el.value || '').trim()) && !$('chatPane').hidden;
    }
    state.refreshVersionLabel = refreshVersionLabel;

    function check() {
      return api('/version').then(function (data) {
        var v = data && data.version;
        if (!v) return null;
        if (!known) { known = v; if (!state.loadedVersion) state.loadedVersion = v; refreshVersionLabel(); return null; }
        if (v === known) return null;
        // 正在通话时绝对不刷新：一刷新连接就断，对方那边就成了「自动挂断」
        if (call) {
          if (!state.versionPendingDuringCall) {
            state.versionPendingDuringCall = v;
            toast('界面有新版本，这通电话结束后会自动刷新');
          }
          return null;
        }
        if (document.hidden || !composerHasDraft()) { location.reload(); return null; }
        toast('界面有新版本：发完这条会自动刷新，或点「更多 → 检查更新」立即刷新');
        return null;
      }).catch(function () { return null; });
    }
    setInterval(check, 15000);
    document.addEventListener('visibilitychange', function () { if (!document.hidden) check(); });
    setTimeout(check, 2500);
  }

  function boot() {
    return api('/session').then(function (data) {
      if (!data.authenticated) throw new Error('未登录');
      state.me = data.user;
      saveAccount(data.user);
      showApp();
      if (state.pendingPairCode) { var pc = state.pendingPairCode; state.pendingPairCode = null; confirmPairLogin(pc); }
      connect();
      return Promise.all([loadChats(), loadContacts()]);
    });
  }

  // 左右比例按微信：左栏 64 / 列表 260 / 聊天区吃剩下的（内联 !important，谁也盖不掉）
  (function () {
    function applySidebarWidth() {
      var sb = document.getElementById('sidebar');
      if (!sb) return;
      var w = window.innerWidth;
      if (w <= 640) {   // 手机版：列表铺满整屏（底部是标签栏）
        sb.style.setProperty('width', '100%', 'important');
        sb.style.setProperty('flex', '1 1 auto', 'important');
      } else if (w <= 1100) {
        sb.style.setProperty('width', '240px', 'important');
        sb.style.setProperty('flex', '0 0 240px', 'important');
      } else {
        sb.style.setProperty('width', '260px', 'important');
        sb.style.setProperty('flex', '0 0 260px', 'important');
      }
    }
    applySidebarWidth();
    var tm = null;
    window.addEventListener('resize', function () {
      clearTimeout(tm);
      tm = setTimeout(applySidebarWidth, 150);
    });
  })();


  // 发送按钮像微信：输入框没内容就是灰的（不可点），一有内容变绿
  (function bindSendState() {
    var input = $('composerInput');
    var btn = $('sendBtn');
    if (!input || !btn) return;
    var sync = function () { try { btn.disabled = !String(input.value || '').trim(); } catch (e) {} };
    input.addEventListener('input', sync);
    input.addEventListener('change', sync);
    input.addEventListener('keyup', sync);
    input.addEventListener('paste', function () { setTimeout(sync, 0); });
    input.addEventListener('blur', sync);
    document.addEventListener('click', function () { setTimeout(sync, 0); });
    setInterval(sync, 500);
    sync();
  })();


  // 发送按钮左边的语音按钮：按住说话、松开发送；按住右 Alt 也一样
  (function bindVoiceShortcut() {
    var btn = $('voiceSendBtn');
    var holding = false;
    function begin() {
      if (holding) return;
      holding = true;
      if (btn) btn.classList.add('is-recording');
      startVoice();
    }
    function end() {
      if (!holding) return;
      holding = false;
      if (btn) btn.classList.remove('is-recording');
      stopVoice(true);
    }
    if (btn) {
      btn.addEventListener('pointerdown', function (e) { e.preventDefault(); begin(); });
      btn.addEventListener('pointerup', function (e) { e.preventDefault(); end(); });
      btn.addEventListener('pointerleave', end);
      btn.addEventListener('pointercancel', end);
    }
    document.addEventListener('keydown', function (e) {
      if (e.code === 'AltRight') { e.preventDefault(); if (!e.repeat) begin(); }
    });
    document.addEventListener('keyup', function (e) {
      if (e.code === 'AltRight') { e.preventDefault(); end(); }
    });
    window.addEventListener('blur', end);
  })();

  setupEvents();
  setupTheme();
  loadBranding();
  startVersionWatch();
  renderAuthAccounts();
  handlePairFromUrl();

  // 软件窗口（launcher 会带 ?app=1）：显示右上角关闭按钮，关掉就是退出窗口
  var isAppWindow = /[?&]app=1(&|$)/.test(location.search);
  if (isAppWindow) {
    try { document.body.classList.add('is-app-window'); } catch (e) { /* 忽略 */ }
    var appClose = $('appCloseBtn');
    if (appClose) appClose.addEventListener('click', function () { try { window.close(); } catch (e) { /* 忽略 */ } });
  }
  // 软件版启动时带着 ?fresh=1：先把上一次的登录状态清掉，必须重新登录才能进
  var forceFreshLogin = /[?&]fresh=1(&|$)/.test(location.search);
  if (forceFreshLogin) {
    try { history.replaceState(null, '', location.pathname + location.hash); } catch (e) { /* 忽略 */ }
  }
  var sessionGate = forceFreshLogin
    ? api('/logout', { method: 'POST' }).catch(function () { return null; })
    : Promise.resolve(null);

  sessionGate
    .then(function () { return api('/session'); })
    .then(function (data) {
      if (data.authenticated) {
        state.me = data.user;
        showApp();
        connect();
        // 带着 ?pair=CODE 过来的已登录设备：弹确认卡片
        if (state.pendingPairCode) {
          var pc = state.pendingPairCode;
          state.pendingPairCode = null;
          setTimeout(function () { confirmPairLogin(pc); }, 300);
        }
        return Promise.all([loadChats(), loadContacts()]);
      }
      $('authScreen').hidden = false;
      setAuthMode(state.authMode || 'login');   // 启动时就按当前模式排好，昵称行占位，切标签不跳位
      consumeAuthNotice();
      if (state.pendingPairCode) { toast('先登录你自己的账号，再来确认这次登录'); }
      if (!forceFreshLogin) maybeAutoLogin();
      $('authUsername').focus();
      return null;
    })
    .catch(function (err) {
      $('authScreen').hidden = false;
      consumeAuthNotice();
      $('authError').hidden = false;
      $('authError').textContent = (err && err.status)
        ? err.message
        : '连不上服务器，请确认服务已启动。';
    });
})();
