/* 登录 / 注册逻辑（极简版）：只用本站接口 */
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var toastEl = $('toast'), toastTimer = null;
  function toast(msg, kind) {
    if (!toastEl) return;
    toastEl.textContent = msg;
    toastEl.className = 'toast on' + (kind ? ' ' + kind : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.className = 'toast'; }, 2600);
  }
  function api(path, opts) {
    opts = opts || {};
    return fetch(path, {
      method: opts.method || 'GET',
      headers: opts.body ? { 'Content-Type': 'application/json' } : {},
      body: opts.body ? JSON.stringify(opts.body) : undefined
    }).then(function (r) {
      return r.text().then(function (t) {
        var j = null; try { j = JSON.parse(t); } catch (e) { }
        if (!r.ok || (j && j.ok === false)) throw new Error((j && j.error) || ('请求失败（HTTP ' + r.status + '）'));
        return j ? (j.data || {}) : {};
      });
    });
  }
  function busy(btn, on) { if (btn) { btn.classList.toggle('loading', !!on); btn.disabled = !!on; } }

  /* ---------------- 同意协议：不勾选不给登 ---------------- */
  var agreeRows = [].slice.call(document.querySelectorAll('.agree'));
  var agreed = false;
  try { agreed = localStorage.getItem('chris-agree-ok') === '1'; } catch (e) { }
  function renderAgree() {
    [].forEach.call(agreeRows, function (r) { r.classList.toggle('on', agreed); });
    ['btnLogin', 'btnReg'].forEach(function (id) {
      var b = $(id); if (b) b.classList.toggle('off', !agreed);
    });
  }
  function needAgree() {
    if (agreed) return true;
    toast('请先勾选并同意《用户协议》和《隐私政策》', 'bad');
    return false;
  }
  [].forEach.call(agreeRows, function (r) {
    r.addEventListener('click', function (e) {
      if (e.target.closest('a')) return;            /* 点协议链接就打开协议，不勾选 */
      agreed = !agreed;
      try { localStorage.setItem('chris-agree-ok', agreed ? '1' : '0'); } catch (e2) { }
      renderAgree();
    });
  });
  renderAgree();
  function isPhone() {
    return /Android|iPhone|iPod|Mobile|HarmonyOS/i.test(navigator.userAgent) ||
      (window.innerWidth <= 700 && 'ontouchstart' in window);
  }
  function goAfterLogin() { location.replace(isPhone() ? '/m.html' : '/index.html?desktop=1'); }

  /* 登录页那个圆圈：显示这台浏览器上「最后登录过的人」的头像 */
  function showLastAvatar() {
    var box = $('iconBox');
    if (!box) return;
    var av = '';
    try { av = localStorage.getItem('chris-last-avatar') || ''; } catch (e) { }
    if (av) {
      box.innerHTML = '<img src="' + av + '" alt="">';
      box.style.background = 'transparent';
      /* 头像一出来，就提示这里可以点：点一下直接进，不用输密码 */
      var tip = $('quickTip');
      if (tip) tip.classList.add('on');
    }
  }
  function rememberMe(u) {
    if (!u) return;
    try {
      if (u.avatar) localStorage.setItem('chris-last-avatar', u.avatar);
      if (u.nickname) localStorage.setItem('chris-last-name', u.nickname);
    } catch (e) { }
  }
  showLastAvatar();

  /* 点头像 = 一键登录：用浏览器里保存的登录态直接进；过期了就让用户重新输密码 */
  function bindQuickLogin() {
    var box = $('iconBox');
    if (!box) return;
    box.style.cursor = 'pointer';
    box.title = '点一下快捷登录';
    box.addEventListener('click', function () {
      api('/api/session').then(function (d) {
        if (d.authenticated) { toast('正在进入…', 'ok'); setTimeout(goAfterLogin, 200); return; }
        // 登录态没了：预填上次的账号，提示重新输密码
        var last = '';
        try { last = localStorage.getItem('chris-last-user') || ''; } catch (e) { }
        if (last && $('loginUser')) $('loginUser').value = last;
        toast('登录状态已过期，请重新输入密码', 'bad');
        if ($('loginPass')) $('loginPass').focus();
      }).catch(function () { toast('连不上服务器', 'bad'); });
    });
  }
  bindQuickLogin();

  /* 用户协议 / 隐私政策：内容来自后台「🎨 登录页」 */
  var termsText = '', privacyText = '';
  function openTerms(kind) {
    var box = $('termsModal');
    if (!box) return;
    $('termsTitle').textContent = kind === 0 ? '用户协议' : '隐私政策';
    var custom = (kind === 0 ? termsText : privacyText || '').trim();
    $('termsBody').textContent = custom || (kind === 0
      ? '1. 本应用是自建的即时通讯软件，账号与数据都保存在你自己的服务器上。\n2. 请勿传播违法违规内容；一经发现，管理员有权封禁账号。\n3. 你的资料仅用于本应用内展示，不会提供给第三方。\n4. 修改密码后，之前的登录令牌会立即失效。'
      : '1. 我们只收集昵称、头像、地区、个性签名和你主动发送的消息与图片。\n2. 这些信息仅用于在本应用内展示和在你的设备之间同步。\n3. 全部保存在你自己的服务器上，不会上传到第三方服务。\n4. 你可以随时修改资料、清空聊天记录，或让管理员删除账号。');
    box.classList.add('on');
  }
  document.addEventListener('click', function (e) {
    var a = e.target.closest('a[href="#"]');
    if (a && /用户协议/.test(a.textContent || '')) { e.preventDefault(); openTerms(0); return; }
    if (a && /隐私政策/.test(a.textContent || '')) { e.preventDefault(); openTerms(1); return; }
    if (e.target.id === 'termsClose' || e.target.id === 'termsModal') $('termsModal').classList.remove('on');
  });

  /* 登录 / 注册 切换 */
  var segMain = $('segMain'), paneLogin = $('paneLogin'), paneReg = $('paneReg');
  function switchTab(tab) {
    [].forEach.call(segMain.querySelectorAll('button'), function (b) {
      b.classList.toggle('on', b.getAttribute('data-tab') === tab);
    });
    paneLogin.classList.toggle('hide', tab !== 'login');
    paneReg.classList.toggle('hide', tab !== 'reg');
    if (tab === 'reg') loadCaptcha();
  }
  segMain.addEventListener('click', function (e) {
    var b = e.target.closest('button'); if (!b) return;
    switchTab(b.getAttribute('data-tab'));
  });
  $('toLogin').addEventListener('click', function () { switchTab('login'); });

  /* 两种登录方式：账号密码 ⇄ 手机验证码 */
  var modePwd = $('modePwd'), modeCode = $('modeCode'), switchMode = $('switchMode');
  switchMode.addEventListener('click', function () {
    var toCode = modeCode.classList.contains('hide');
    modePwd.classList.toggle('hide', toCode);
    modeCode.classList.toggle('hide', !toCode);
    switchMode.textContent = toCode ? '用账号密码登录' : '用手机验证码登录';
    /* 滑动验证只管账号密码登录，而且是**按需**才出现（服务端判定有风险才弹），
       切过来的时候别把它翻出来 */
    hideSliderBox();
  });

  /* 密码显示 / 隐藏 */
  function bindEye(btnId, inputId) {
    var b = $(btnId), i = $(inputId);
    if (!b || !i) return;
    b.addEventListener('click', function () {
      var show = i.type === 'password';
      i.type = show ? 'text' : 'password';
      b.textContent = show ? '隐藏' : '显示';
    });
  }
  bindEye('eyeLogin', 'loginPass');
  bindEye('eyeReg', 'regPass');

  try {
    var last = localStorage.getItem('chris-last-user');
    if (last && $('loginUser')) $('loginUser').value = last;
  } catch (e) { }

  /* 图形验证码 */
  var capId = '';
  function loadCaptcha() {
    var box = $('capBox'); if (!box) return;
    box.innerHTML = '<span style="color:#aaa;font-size:12px">加载中</span>';
    api('/api/captcha').then(function (d) {
      capId = d.id || '';
      box.innerHTML = d.svg || '';
    }).catch(function () { box.innerHTML = '<span style="color:#c33;font-size:12px">点我再试</span>'; });
  }
  $('capBox').addEventListener('click', loadCaptcha);

  /* 获取手机验证码 */
  var codeTimer = null;
  $('getCode').addEventListener('click', function () {
    var btn = this;
    var phone = ($('loginPhone').value || '').trim();
    if (!/^1[3-9]\d{9}$/.test(phone)) return toast('手机号要 11 位', 'bad');
    busy(btn, true);
    api('/api/login/phone-code', { method: 'POST', body: { phone: phone } }).then(function (d) {
      if (d.devCode) {
        $('loginCode').value = d.devCode;
        toast('验证码已自动填好：' + d.devCode, 'ok');
      } else {
        toast('验证码已发送，请看手机', 'ok');
      }
      var left = 60;
      btn.disabled = true; btn.textContent = left + 's';
      codeTimer = setInterval(function () {
        left -= 1;
        if (left <= 0) { clearInterval(codeTimer); btn.disabled = false; btn.textContent = '获取验证码'; }
        else btn.textContent = left + 's';
      }, 1000);
    }).catch(function (e) { toast(e.message, 'bad'); busy(btn, false); });
  });

  /* ── 登录滑动验证（拖滑块补缺口）────────────────────────────────
     服务端出题 → 这里画图 + 让用户拖 → 松手交卷 → 换来一张一次性通行证。
     通行证随登录请求一起发；用掉了/过期了会自动换一道新题。
     注意：客户端不自己判对错，位置对不对是服务端说的。               */
  var sliderTicket = '', sliderId = '', sliderX = 0, sliderMax = 0, sliderPiece = 44, sliderDone = false;
  /* 服务器没开滑动验证时，这一块直接收起来（开关在 data/security.json 的 sliderLogin） */
  var sliderOn = true;
  /* 滑块默认藏着（跟微信一样）：只有服务端判定这次登录有风险才滑出来；
     滑完自动把刚才被拦下的那次登录重试一遍，不用用户再点一次「登录」 */
  var pendingLogin = false;
  function showSliderBox() {
    var sw = $('sliderWrap');
    if (!sw || !sliderOn) return;
    sw.classList.add('show');
    sw.style.display = '';
    if (typeof loadSlider === 'function') loadSlider();
  }
  function hideSliderBox() {
    var sw = $('sliderWrap');
    if (!sw) return;
    sw.classList.remove('show');
    sw.style.display = 'none';
  }

  function sf(seed, i) {                 // 稳定的伪随机（同一个 seed 画出来一样）
    var x = (Math.imul(seed + i * 7 + 13, 2654435761) >>> 0);
    x ^= x >>> 13; x = Math.imul(x, 1274126177) >>> 0; x ^= x >>> 16;
    return 0.08 + (x % 1000) / 1000 * 0.84;
  }
  function sc(seed, i) {
    var hues = [203, 214, 262, 172, 318, 20, 120];
    return 'hsl(' + hues[(seed + i * 3) % hues.length] + ',48%,' + (58 + ((seed + i) % 3) * 6) + '%)';
  }
  function sceneHTML(seed, w, h) {
    var s = '<div style="position:absolute;left:0;top:0;width:100%;height:100%;'
          + 'background:linear-gradient(135deg,' + sc(seed, 0) + ',' + sc(seed, 1) + ')"></div>';
    for (var i = 0; i < 5; i++) {
      var bw = w * sf(seed, i * 4 + 1) * 0.8;
      var bh = Math.max(12, h * sf(seed, i * 4 + 2) * 0.5);
      var rot = sf(seed, i * 4 + 3) * 180 - 90;
      var cx = w * sf(seed, i * 4 + 4), cy = h * sf(seed, i * 4 + 1);
      s += '<div style="position:absolute;left:' + (cx - bw / 2).toFixed(1) + 'px;top:' + (cy - bh / 2).toFixed(1)
        + 'px;width:' + bw.toFixed(1) + 'px;height:' + bh.toFixed(1) + 'px;border-radius:' + (bh / 2).toFixed(1)
        + 'px;background:' + sc(seed, i + 2) + ';opacity:.45;transform:rotate(' + rot.toFixed(1) + 'deg)"></div>';
    }
    return s;
  }

  function loadSlider() {
    var wrap = $('sliderWrap');
    if (!wrap) return Promise.resolve(false);
    sliderDone = false; sliderTicket = ''; sliderX = 0;
    wrap.classList.remove('ok');
    $('sliderHandle').classList.remove('done');
    $('sliderHandle').textContent = '››';
    $('sliderHint').textContent = '按住滑块，拖到最右边';
    $('sliderHandle').style.left = '0px';
    $('sliderPiece').style.left = '0px';
    $('sliderFill').style.width = '0px';
    return api('/api/slider').then(function (d) {
      sliderId = d.id; sliderPiece = d.piece || 44;
      sliderMax = Math.max(1, (d.width || 260) - sliderPiece);
      var w = d.width || 260, h = d.height || 130;
      $('sliderPuzzle').style.height = h + 'px';
      $('sliderTrack').style.height = sliderPiece + 'px';
      $('sliderHandle').style.width = sliderPiece + 'px';
      $('sliderHole').style.width = sliderPiece + 'px';
      $('sliderHole').style.height = sliderPiece + 'px';
      $('sliderHole').style.left = (d.targetX || 0) + 'px';
      $('sliderHole').style.top = (d.targetY || 0) + 'px';
      $('sliderPiece').style.width = sliderPiece + 'px';
      $('sliderPiece').style.height = sliderPiece + 'px';
      $('sliderPiece').style.top = (d.targetY || 0) + 'px';
      $('sliderSceneBack').innerHTML = sceneHTML(d.seed || 1, w, h);
      /* 滑块里那块内容 = 同一张图，向左上偏移缺口的位置 —— 推到位就正好补齐 */
      $('sliderScenePiece').style.width = w + 'px';
      $('sliderScenePiece').style.height = h + 'px';
      $('sliderScenePiece').style.left = '-' + (d.targetX || 0) + 'px';
      $('sliderScenePiece').style.top = '-' + (d.targetY || 0) + 'px';
      $('sliderScenePiece').innerHTML = sceneHTML(d.seed || 1, w, h);
      return true;
    }).catch(function () {
      $('sliderHint').textContent = '验证加载失败，点一下重试';
      return false;
    });
  }

  function submitSlider() {
    if (!sliderId || sliderDone) return Promise.resolve(sliderDone);
    $('sliderHint').textContent = '正在核对…';
    return api('/api/slider/verify', { method: 'POST', body: { id: sliderId, x: sliderX } })
      .then(function (d) {
        sliderTicket = d.ticket || '';
        sliderDone = !!sliderTicket;
        if (!sliderDone) return loadSlider().then(function () { return false; });
        $('sliderWrap').classList.add('ok');
        $('sliderHandle').classList.add('done');
        $('sliderHandle').textContent = '✓';
        $('sliderHint').textContent = '验证通过';
        /* 这次验证是为「刚才被拦下的那次登录」做的：自动重试，不用再点一次登录 */
        if (pendingLogin) {
          pendingLogin = false;
          setTimeout(function () { var b = $('btnLogin'); if (b) b.click(); }, 260);
        }
        return true;
      })
      .catch(function (e) {
        $('sliderHint').textContent = (e && e.message) || '没对上，再试一次';
        return loadSlider().then(function () { return false; });
      });
  }

  (function bindSliderDrag() {
    var track = $('sliderTrack');
    if (!track) return;
    var dragging = false;
    function moveTo(clientX) {
      var rect = track.getBoundingClientRect();
      var x = clientX - rect.left - sliderPiece / 2;
      sliderX = Math.max(0, Math.min(sliderMax, x));
      $('sliderHandle').style.left = sliderX + 'px';
      $('sliderPiece').style.left = sliderX + 'px';
      $('sliderFill').style.width = (sliderX + sliderPiece) + 'px';
    }
    track.addEventListener('pointerdown', function (e) {
      if (sliderDone) return;
      dragging = true;
      try { track.setPointerCapture(e.pointerId); } catch (err) { }
      moveTo(e.clientX);
    });
    track.addEventListener('pointermove', function (e) { if (dragging) moveTo(e.clientX); });
    function up(e) {
      if (!dragging) return;
      dragging = false;
      try { track.releasePointerCapture(e.pointerId); } catch (err) { }
      submitSlider();
    }
    track.addEventListener('pointerup', up);
    track.addEventListener('pointercancel', up);
    loadSlider();
  })();

  /* 登录 */
  $('btnLogin').addEventListener('click', function () {
    var btn = this;
    if (!needAgree()) return;
    var codeMode = !modeCode.classList.contains('hide');
    var url, body;
    if (codeMode) {
      var phone = ($('loginPhone').value || '').trim();
      var code = ($('loginCode').value || '').trim();
      if (!/^1[3-9]\d{9}$/.test(phone)) return toast('请填写 11 位手机号', 'bad');
      if (!/^\d{4,8}$/.test(code)) return toast('请填写验证码', 'bad');
      url = '/api/login/phone'; body = { phone: phone, code: code };
    } else {
      var u = ($('loginUser').value || '').trim();
      var p = $('loginPass').value || '';
      if (!u) return toast('请填写微信号 / 用户名', 'bad');
      if (!p) return toast('请填写密码', 'bad');
      /* 直接登：上次滑出来的票还在就带上。服务端默认放行，
         只有判定有风险才回 428（needSlider），那时才把滑块滑出来 */
      url = '/api/login'; body = { username: u, password: p };
      if (sliderTicket) body.sliderTicket = sliderTicket;
    }
    busy(btn, true);
    api(url, { method: 'POST', body: body }).then(function (d) {
      if (!codeMode) { try { localStorage.setItem('chris-last-user', body.username); } catch (e) { } }
      if (d.token) { try { localStorage.setItem('chris.token', d.token); } catch (e) { } }
      rememberMe(d.user);
      toast('登录成功', 'ok');
      setTimeout(goAfterLogin, 350);
    }).catch(function (e) {
      busy(btn, false);
      if (e && e.needSlider) {
        /* 服务端判定这次有风险：把滑块「滑出来」（平时它是收着的） */
        toast('为确认是本人操作，请完成安全验证', 'bad');
        pendingLogin = true;
        showSliderBox();
      } else {
        toast(e.message, 'bad');
        /* 通行证是一次性的：这次没生效（被别的请求用掉 / 过期）就换一道新题 */
        if (/滑动验证|安全验证/.test(String(e.message || ''))) {
          pendingLogin = true;
          showSliderBox();
        }
      }
      /* 被封的账号：直接把自助解封那一页摊开，省得他自己找 */
      if (/禁用|封禁/.test(String(e.message || ''))) showUnban(true);
    });
  });
  function enterToLogin(e) { if (e.key === 'Enter') $('btnLogin').click(); }
  modePwd.addEventListener('keydown', enterToLogin);
  modeCode.addEventListener('keydown', enterToLogin);

  /* ---------------- 身份证自助解封 ---------------- */
  function showUnban(on) {
    $('paneLogin').classList.toggle('hide', on);
    $('paneReg').classList.add('hide');
    $('paneUnban').classList.toggle('hide', !on);
    $('segMain').classList.toggle('hide', on);
    if (on) {
      /* 把刚才填的账号密码带过去，别让人再输一遍 */
      if (!$('unbUser').value && $('loginUser').value) $('unbUser').value = $('loginUser').value.trim();
      if (!$('unbPass').value && $('loginPass').value) $('unbPass').value = $('loginPass').value;
      setTimeout(function () { $('unbId').focus(); }, 60);
    }
  }

  /* ---------------- 密码找回（手机号 + 验证码 + 新密码） ---------------- */

  /* ---------------- 第三方授权登录（微信 / QQ 入口，走自建的设备确认登录） ---------------- */
  var authTimer = null, authCode = '';
  function stopAuth() {
    if (authTimer) { clearInterval(authTimer); authTimer = null; }
    authCode = '';
    $('authBox').classList.remove('on');
    $('authCode').textContent = '······';
    $('authQr').innerHTML = '';
  }
  function startAuth(name) {
    stopAuth();
    api('/api/pair/start', { method: 'POST', body: {} }).then(function (d) {
      authCode = d.code || '';
      $('authCode').textContent = authCode || '······';
      $('authBox').classList.add('on');
      $('authHint').textContent = (name || '第三方') + '授权：在已登录的设备上点「我 → 设置 → 设备确认登录」，输入上面的数字';
      api('/api/qr?text=' + encodeURIComponent(authCode) + '&scale=6').then(function (q) {
        if (q && q.svg) $('authQr').innerHTML = q.svg;
      }).catch(function () { });
      authTimer = setInterval(function () {
        if (!authCode) return;
        api('/api/pair/status?code=' + encodeURIComponent(authCode)).then(function (r) {
          if (r.status === 'approved') {
            stopAuth();
            if (r.token) { try { localStorage.setItem('chris.token', r.token); } catch (e) { } }
            rememberMe(r.user);
            toast('授权成功，正在进入…', 'ok');
            setTimeout(goAfterLogin, 350);
          } else if (r.status === 'expired') {
            stopAuth();
            toast('这个码过期了，重新点一次授权登录', 'bad');
          }
        }).catch(function () { });
      }, 2000);
    }).catch(function (e) { toast(e.message, 'bad'); });
  }
  $('authWx').addEventListener('click', function () { startAuth('星言'); });
  $('authQq').addEventListener('click', function () { startAuth('QQ'); });
  $('authCancel').addEventListener('click', stopAuth);
  function showReset(on) {
    $('paneLogin').classList.toggle('hide', on);
    $('paneReg').classList.add('hide');
    $('paneUnban').classList.add('hide');
    $('paneReset').classList.toggle('hide', !on);
    $('segMain').classList.toggle('hide', on);
    if (on && $('resetPhone') && !$('resetPhone').value) {
      $('resetPhone').value = ($('loginPhone') && $('loginPhone').value) || '';
    }
  }
  $('forgotPwd').addEventListener('click', function () { showReset(true); });
  $('backFromReset').addEventListener('click', function () { showReset(false); });
  bindEye('eyeReset', 'resetPass');

  var resetTimer = null;
  $('getResetCode').addEventListener('click', function () {
    var btn = this;
    var phone = ($('resetPhone').value || '').trim();
    if (!/^1[3-9]\d{9}$/.test(phone)) return toast('手机号要 11 位', 'bad');
    busy(btn, true);
    api('/api/login/phone-code', { method: 'POST', body: { phone: phone } }).then(function (d) {
      if (d.devCode) {
        $('resetCode').value = d.devCode;
        toast('验证码已自动填好：' + d.devCode, 'ok');
      } else {
        toast('验证码已发送，请看手机', 'ok');
      }
      var left = 60;
      btn.disabled = true; btn.textContent = left + 's';
      resetTimer = setInterval(function () {
        left -= 1;
        if (left <= 0) { clearInterval(resetTimer); btn.disabled = false; btn.textContent = '获取验证码'; }
        else btn.textContent = left + 's';
      }, 1000);
    }).catch(function (e) { toast(e.message, 'bad'); busy(btn, false); });
  });

  $('btnReset').addEventListener('click', function () {
    var btn = this;
    var phone = ($('resetPhone').value || '').trim();
    var code = ($('resetCode').value || '').trim();
    var pass = $('resetPass').value || '';
    if (!/^1[3-9]\d{9}$/.test(phone)) return toast('请填写 11 位手机号', 'bad');
    if (!code) return toast('请填写验证码', 'bad');
    if (pass.length < 6) return toast('新密码至少 6 位', 'bad');
    busy(btn, true);
    api('/api/login/reset', { method: 'POST', body: { phone: phone, code: code, newPassword: pass } })
      .then(function (d) {
        if (d.token) { try { localStorage.setItem('chris.token', d.token); } catch (e) { } }
        rememberMe(d.user);
        toast('密码已重置，正在进入…', 'ok');
        setTimeout(goAfterLogin, 400);
      })
      .catch(function (e) { busy(btn, false); toast(e.message, 'bad'); });
  });
  $('paneReset').addEventListener('keydown', function (e) { if (e.key === 'Enter') $('btnReset').click(); });
  $('openUnban').addEventListener('click', function () { showUnban(true); });
  $('backLogin').addEventListener('click', function () { showUnban(false); });
  $('eyeUnb').addEventListener('click', function () {
    var el = $('unbPass');
    var show = el.type === 'password';
    el.type = show ? 'text' : 'password';
    this.textContent = show ? '隐藏' : '显示';
  });
  /* 身份证：只留数字和 X，边输边提示还差几位 */
  $('unbId').addEventListener('input', function () {
    var v = (this.value || '').toUpperCase().replace(/[^0-9X]/g, '').slice(0, 18);
    this.value = v;
  });
  $('btnUnban').addEventListener('click', function () {
    var btn = this;
    var u = ($('unbUser').value || '').trim();
    var p = $('unbPass').value || '';
    var idc = ($('unbId').value || '').trim().toUpperCase();
    if (!u) return toast('请填写被封的账号', 'bad');
    if (!p) return toast('请填写账号密码', 'bad');
    if (!/^\d{17}[\dX]$/.test(idc)) return toast('身份证要 18 位，最后一位可以是 X', 'bad');
    busy(btn, true);
    api('/api/unban', { method: 'POST', body: { username: u, password: p, idCard: idc } }).then(function (d) {
      rememberMe(d.user);
      toast('解封成功，正在登录…', 'ok');
      setTimeout(goAfterLogin, 500);
    }).catch(function (e) { busy(btn, false); toast(e.message, 'bad'); });
  });
  $('paneUnban').addEventListener('keydown', function (e) { if (e.key === 'Enter') $('btnUnban').click(); });

  /* 注册 */
  $('btnReg').addEventListener('click', function () {
    var btn = this;
    if (!needAgree()) return;
    var u = ($('regUser').value || '').trim();
    var nick = ($('regNick').value || '').trim();
    var p = $('regPass').value || '';
    var cap = ($('regCap').value || '').trim();
    if (!/^[A-Za-z0-9_]{3,24}$/.test(u)) return toast('用户名要 3-24 位字母/数字/下划线', 'bad');
    if (p.length < 6) return toast('密码至少 6 位', 'bad');
    if (!cap) return toast('请填写图形验证码', 'bad');
    busy(btn, true);
    api('/api/register', { method: 'POST', body: { username: u, nickname: nick || u, password: p, captchaId: capId, captcha: cap } })
      .then(function () {
        /* 注册接口本身就把登录态发下来了（Set-Cookie），
           不用再走一次 /api/login —— 那条路现在还要过滑动验证。 */
        toast('注册成功，正在进入…', 'ok');
      })
      .then(function (d) {
        d = d || {};
        if (d.token) { try { localStorage.setItem('chris.token', d.token); } catch (e) { } }
        try { localStorage.setItem('chris-last-user', u); } catch (e) { }
        setTimeout(goAfterLogin, 450);
      })
      .catch(function (e) { busy(btn, false); toast(e.message, 'bad'); loadCaptcha(); });
  });
  $('paneReg').addEventListener('keydown', function (e) { if (e.key === 'Enter') $('btnReg').click(); });

  /* 后台可配的外观：颜色 / 背景图 / 图标 / 文案 */
  var THEME = null;
  function hex(v, dft) { return /^#[0-9a-fA-F]{6}$/.test(String(v || '')) ? v : dft; }
  function applyTheme() {
    if (!THEME) return;
    var dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
    var root = document.documentElement.style;
    root.setProperty('--acc', hex(dark ? THEME.darkAccent : THEME.accent, '#07C160'));
    root.setProperty('--bg', hex(dark ? THEME.darkBg : THEME.bg, dark ? '#111214' : '#f2f3f5'));
    root.setProperty('--card', hex(dark ? THEME.darkCard : THEME.card, dark ? '#1c1c1e' : '#ffffff'));
    root.setProperty('--txt', hex(dark ? THEME.darkText : THEME.text, dark ? '#eceff3' : '#181818'));
    root.setProperty('--sub', hex(THEME.sub, dark ? '#8b9099' : '#8a8f99'));
    var acc = hex(dark ? THEME.darkAccent : THEME.accent, '#07C160');
    var m = /^#(..)(..)(..)$/.exec(acc);
    if (m) {
      root.setProperty('--acc-press', '#' + [m[1], m[2], m[3]].map(function (x) {
        var n = Math.max(0, Math.round(parseInt(x, 16) * 0.88));
        return ('0' + n.toString(16)).slice(-2);
      }).join(''));
    }
    if (THEME.bgImage) {
      document.body.style.backgroundImage = 'url("' + THEME.bgImage + '")';
      document.body.style.backgroundSize = 'cover';
      document.body.style.backgroundPosition = 'center';
      document.body.style.backgroundRepeat = 'no-repeat';
    } else {
      document.body.style.backgroundImage = '';
    }
  }
  var prevDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)');
  if (prevDark && prevDark.addEventListener) prevDark.addEventListener('change', applyTheme);

  api('/api/branding').then(function (d) {
    var b = d.branding || {};
    var L = b.login || {};
    /* 滑动验证开没开：服务器说了算（关了就把这一块收起来，也不用再交卷） */
    sliderOn = b.sliderLogin !== false;
    hideSliderBox();          // 默认收着，服务端要了再滑出来
    THEME = L;
    if (L.appName || b.appName) {
      var name = L.appName || b.appName;
      document.title = '登录 · ' + name;
      $('brandName').textContent = name;
    }
    if (L.subTitle) $('headSub').textContent = L.subTitle;
    termsText = L.terms || '';
    privacyText = L.privacy || '';
    if (L.logo) {
      var ic = document.querySelector('.icon');
      if (ic) ic.innerHTML = '<img src="' + L.logo + '" alt="" style="width:100%;height:100%;object-fit:cover;border-radius:19px">';
    }
    applyTheme();
  }).catch(function () { });

  /* 预览模式（后台的实时预览）不自动跳走 */
  if (location.search.indexOf('nologin=1') < 0) {
    api('/api/session').then(function (d) { if (d.authenticated) goAfterLogin(); }).catch(function () { });
  }

  /* 直达锚点：login.html#reg / #code / #unban / #terms 直接打开对应界面 */
  var hash = (location.hash || '').replace('#', '');
  if (hash === 'reg') switchTab('reg');
  else if (hash === 'code') switchMode.click();
  else if (hash === 'unban') showUnban(true);
  else if (hash === 'reset') showReset(true);
  else if (hash === 'terms' || hash === 'privacy') openTerms(hash === 'terms' ? 0 : 1);
})();
