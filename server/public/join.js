/* 群二维码扫码进来这一页：带着邀请码调接口进群；没登录就先去登录，登录完自动接着进 */
(function () {
  var code = '';
  try { code = new URLSearchParams(location.search).get('c') || ''; } catch (e) { }
  var t = document.getElementById('title');
  var s = document.getElementById('sub');
  var btn = document.getElementById('btn');
  var ico = document.getElementById('ico');

  function fail(msg) {
    ico.textContent = '⚠️';
    t.textContent = '进群失败';
    s.textContent = msg;
    btn.style.display = 'block';
    btn.textContent = '回到聊天';
    btn.href = '/m.html';
  }

  if (!code) { fail('这个二维码里没有邀请码，让群主重新生成一张'); return; }

  fetch('/api/join', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ code: code })
  }).then(function (r) {
    return r.text().then(function (x) {
      var j = null; try { j = JSON.parse(x); } catch (e) { }
      return { ok: r.ok, status: r.status, j: j };
    });
  }).then(function (res) {
    if (res.ok && res.j && res.j.ok) {
      ico.textContent = '✅';
      t.textContent = res.j.data && res.j.data.already ? '你已经在这个群里了' : '进群成功';
      s.textContent = (res.j.data && res.j.data.chat && res.j.data.chat.title) || '群聊';
      btn.style.display = 'block';
      setTimeout(function () { location.replace('/m.html'); }, 800);
      return;
    }
    var msg = (res.j && res.j.error) || '进群失败';
    if (!res.ok || /登录/.test(msg)) {
      /* 没登录：把码记下来，去登录，登录完 m.js 会自动接着进群 */
      try { localStorage.setItem('chris.pendingJoin', code); } catch (e) { }
      t.textContent = '先登录一下';
      s.textContent = '登录完成后会自动帮你进群';
      btn.style.display = 'block';
      btn.textContent = '去登录';
      btn.href = '/login.html';
      setTimeout(function () { location.replace('/login.html'); }, 900);
      return;
    }
    fail(msg);
  }).catch(function () { fail('连不上服务器'); });
})();
