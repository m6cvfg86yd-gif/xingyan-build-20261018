/* App 页面预览：登录页 + 手机号登录 + 转账 4 页，颜色全部读后台配置 */
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var page = 'login', dark = false, agree = false;
  var lastAvatar = ''; try { lastAvatar = localStorage.getItem('chris-last-avatar') || ''; } catch (e) { }
  var cfg = { branding: {}, login: {} };
  function hex(v, dft) { return /^#[0-9a-fA-F]{6}$/.test(String(v || '')) ? v : dft; }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]; }); }

  var SAMPLE = { name: '张伟', account: 'zhangwei', amount: '100.00', remark: '测试转账' };

  function colors() {
    var L = cfg.login || {};
    return {
      accent: hex(dark ? (L.darkAccent || L.accent) : L.accent, '#07C160'),
      accent2: hex(L.accent2, '#007AFF'),
      disabled: hex(L.disabledAccent, '#B2E4C8'),
      gray: hex(L.disabledGray, '#C7C7CC'),
      bg: hex(dark ? L.darkBg : L.bg, dark ? '#111214' : '#ffffff'),
      text: hex(dark ? L.darkText : L.text, dark ? '#eceff3' : '#000000'),
      sub: hex(L.sub, dark ? '#98989f' : '#8E8E93'),
      gray6: dark ? '#1c1c1e' : '#F2F2F7',
      appName: L.appName || cfg.branding.appName || '我的App',
      logo: L.logo || cfg.branding.logo || '',
      bgImage: L.bgImage || ''
    };
  }

  function paintRoot() {
    var c = colors(), root = document.documentElement.style;
    root.setProperty('--accent', c.accent);
    root.setProperty('--accent2', c.accent2);
    root.setProperty('--disabled', c.disabled);
    root.setProperty('--gray', c.gray);
    root.setProperty('--bg', c.bg);
    root.setProperty('--text', c.text);
    root.setProperty('--sub', c.sub);
    root.setProperty('--gray6', c.gray6);
    document.body.classList.toggle('dark', dark);
  }

  function render() {
    paintRoot();
    var c = colors();
    /* 背景图：只有「账号登录」这页铺（跟 App 一致） */
    var screen = document.getElementById('screen');
    if (page === 'login' && c.bgImage) {
      screen.style.backgroundImage = 'linear-gradient(rgba(255,255,255,.30),rgba(255,255,255,.30)), url("' + c.bgImage + '")';
      screen.style.backgroundSize = 'cover';
      screen.style.backgroundPosition = 'center';
    } else {
      screen.style.backgroundImage = '';
    }
    var titles = { login: '账号登录', phone: '手机号登录', t1: '转账', t2: '确认转账', t3: '验证支付密码', t4: '转账结果' };
    $('navTitle').textContent = titles[page] || '';
    var h = '';

    if (page === 'login') {
      h += '<div class="loginBody" style="display:flex;flex-direction:column;flex:1">'
        + '<div class="logo">' + (lastAvatar ? '<img src="' + esc(lastAvatar) + '">' : (c.logo ? '<img src="' + esc(c.logo) + '">'
          : '<svg viewBox="0 0 24 24" width="34" height="34" fill="' + (dark ? '#3a3a3c' : '#c7c7cc') + '"><path d="M12 2C6.5 2 2 5.8 2 10.5c0 2.7 1.5 5.1 3.9 6.6L5 21l4-2.1c1 .2 2 .3 3 .3 5.5 0 10-3.8 10-8.7S17.5 2 12 2z"/></svg>')) + '</div>'
        + '<div class="name">' + esc(c.appName) + '</div>'
        + '<div class="hello">欢迎回来，请选择登录方式</div>'
        + '<div class="wechat ' + (agree ? 'on' : '') + '"><svg viewBox="0 0 24 24"><path d="M12 2C6.5 2 2 5.8 2 10.5c0 2.7 1.5 5.1 3.9 6.6L5 21l4-2.1c1 .2 2 .3 3 .3 5.5 0 10-3.8 10-8.7S17.5 2 12 2z"/></svg>微信登录</div>'
        + '<div class="ways">手机号登录<span class="line">｜</span>账号密码登录</div>'
        + '<div class="agree"><div class="box ' + (agree ? 'on' : '') + '"><i></i></div>'
        + '<div>我已阅读并同意 <a href="#">《用户协议》</a> 和 <a href="#">《隐私政策》</a></div></div>'
        + '<div class="ver">V1.0.0</div></div>';
    } else if (page === 'phone') {
      h += '<div class="h1left">手机号登录</div>'
        + '<div class="field">请输入手机号</div>'
        + '<div class="row"><div class="field">请输入验证码</div><div class="btncode">获取验证码</div></div>'
        + '<div class="bigbtn">登录</div>'
        + '<div class="agree" style="margin-top:24px"><div class="box' + (agree ? ' on' : '') + '"><i></i></div>'
        + '<div>我已阅读并同意 <a href="#">《用户协议》</a> 和 <a href="#">《隐私政策》</a></div></div>';
    } else if (page === 't1') {
      h += '<div class="field">收款人姓名｜' + esc(SAMPLE.name) + '</div>'
        + '<div class="field">收款账号/手机号｜' + esc(SAMPLE.account) + '</div>'
        + '<div style="margin-top:18px;font-size:14px;color:var(--sub)">转账金额</div>'
        + '<div class="field" style="display:flex;gap:6px;align-items:baseline"><b style="font-size:24px;color:var(--text)">¥</b><b style="font-size:24px;color:var(--text)">' + SAMPLE.amount + '</b></div>'
        + '<div class="field">备注（选填）｜' + esc(SAMPLE.remark) + '</div>'
        + '<div class="bigbtn">下一步</div>';
    } else if (page === 't2') {
      h += '<div class="card"><div class="center" style="font-size:18px;font-weight:600;margin-bottom:10px">确认转账信息</div>'
        + '<div class="kv"><span class="k">收款人</span><span>' + esc(SAMPLE.name) + '</span></div>'
        + '<div class="kv"><span class="k">收款账号</span><span>' + esc(SAMPLE.account) + '</span></div>'
        + '<div class="kv"><span class="k">转账金额</span><span>¥' + SAMPLE.amount + '</span></div>'
        + '<div class="kv"><span class="k">手续费</span><span>¥0.00</span></div>'
        + '<div class="kv"><span class="k">备注</span><span>' + esc(SAMPLE.remark) + '</span></div>'
        + '<div class="kv total"><span>合计</span><span class="v">¥' + SAMPLE.amount + '</span></div></div>'
        + '<div class="bigbtn">确认转账</div>';
    } else if (page === 't3') {
      h += '<div class="center" style="font-size:18px;font-weight:600;margin-top:16px">请输入支付密码</div>'
        + '<div class="muted" style="margin-top:6px">转账金额 ¥' + SAMPLE.amount + '</div>'
        + '<div class="pwdbox">' + [0, 0, 0, 0, 0, 0].map(function (_, i) { return '<div>' + (i < 3 ? '<i></i>' : '') + '</div>'; }).join('') + '</div>'
        + '<div class="muted" style="margin-top:14px">（键盘输入 6 位数字后自动提交）</div>'
        + '<div style="margin-top:auto" class="center"><a href="#" style="color:var(--accent2);font-size:14px;text-decoration:none">忘记密码？</a></div>';
    } else if (page === 't4') {
      h += '<div style="flex:1;display:flex;flex-direction:column;justify-content:center">'
        + '<div class="ok"><svg viewBox="0 0 24 24"><path d="M9.6 16.8l-4-4L4.2 14.2l5.4 5.4 11-11-1.4-1.4z"/></svg></div>'
        + '<div class="name" style="margin-top:20px">转账成功</div>'
        + '<div class="amount" style="margin-top:6px">¥' + SAMPLE.amount + '</div>'
        + '<div class="muted" style="margin-top:6px">预计实时到账</div></div>'
        + '<div class="bigbtn green" style="background:var(--gray6);color:var(--accent2)">查看账单</div>'
        + '<div class="bigbtn">返回首页</div>';
    }
    $('pageBody').innerHTML = h;
  }

  $('tabs').addEventListener('click', function (e) {
    var b = e.target.closest('button'); if (!b) return;
    if (b.id === 'bLight') { dark = false; $('bLight').classList.add('on'); $('bDark').classList.remove('on'); return render(); }
    if (b.id === 'bDark') { dark = true; $('bDark').classList.add('on'); $('bLight').classList.remove('on'); return render(); }
    var p = b.getAttribute('data-p'); if (!p) return;
    page = p;
    [].forEach.call($('tabs').querySelectorAll('[data-p]'), function (x) { x.classList.toggle('on', x === b); });
    render();
  });
  /* 点协议行切换勾选，看按钮两种状态 */
  $('pageBody').addEventListener('click', function (e) {
    if (e.target.closest('.agree')) { agree = !agree; render(); }
  });

  fetch('/api/branding').then(function (r) { return r.json(); }).then(function (j) {
    var d = (j && j.data) || {};
    cfg.branding = d.branding || {};
    cfg.login = cfg.branding.login || {};
    render();
  }).catch(render);
  render();
})();
