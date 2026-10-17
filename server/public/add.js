/* 扫到别人的个人二维码，打开这一页：加好友；没登录就先去登录，登录完成自动接着加 */
(function () {
  var code = '';
  try { code = new URLSearchParams(location.search).get('u') || ''; } catch (e) { }
  var t = document.getElementById('title');
  var s = document.getElementById('sub');
  var btn = document.getElementById('btn');
  var ico = document.getElementById('ico');
  var av = document.getElementById('av');

  function show(user) {
    ico.style.display = 'none';
    if (user && user.avatar) { av.src = user.avatar; av.style.display = 'block'; }
  }
  function fail(msg) {
    ico.textContent = '⚠️';
    t.textContent = '打不开这张二维码';
    s.textContent = msg;
    btn.style.display = 'block';
  }

  if (!code) { fail('码不对，让朋友重新给你看一下他的二维码'); return; }

  function post() {
    return fetch('/api/add-by-code', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code: code })
    }).then(function (r) {
      return r.text().then(function (x) {
        var j = null; try { j = JSON.parse(x); } catch (e) { }
        return { ok: r.ok, j: j };
      });
    });
  }

  post().then(function (res) {
    if (res.ok && res.j && res.j.ok) {
      var d = res.j.data || {};
      var u = d.user || {};
      show(u);
      t.textContent = u.nickname || '已发送';
      s.textContent = d.already ? '你们已经是好友了'
        : (d.pending ? '已经发过申请了，等对方通过'
          : (d.accepted ? '对方之前加过你，现在已经是好友'
            : '好友申请已发出，等对方通过'));
      btn.style.display = 'block';
      return;
    }
    var msg = (res.j && res.j.error) || '加好友失败';
    if ((res.j && res.j.error === '请先登录') || /登录/.test(msg)) {
      try { localStorage.setItem('chris.pendingAdd', code); } catch (e) { }
      ico.textContent = '🔑';
      t.textContent = '先登录一下';
      s.textContent = '登录完成后会自动帮你发好友申请';
      btn.style.display = 'block';
      btn.textContent = '去登录';
      btn.href = '/login.html';
      setTimeout(function () { location.replace('/login.html'); }, 900);
      return;
    }
    fail(msg);
  }).catch(function () { fail('连不上服务器'); });
})();
