/* 通话通道自检：按后台配置收集 ICE 候选，看有没有 relay（中继）候选。
   单独放一个文件是因为页面有 CSP，内联脚本会被挡掉。 */
(function () {
  function show(id, html) { var el = document.getElementById(id); if (el) el.innerHTML = html; }
  var DEFAULT = [
    { urls: ['stun:stun.miwifi.com:3478', 'stun:stun.cloudflare.com:3478', 'stun:stun.l.google.com:19302'] },
    { urls: ['turn:' + location.hostname + ':3478?transport=tcp', 'turn:' + location.hostname + ':3478?transport=udp'],
      username: 'chris', credential: 'chris1234' }
  ];
  fetch('/api/branding').then(function (r) { return r.json(); }).then(function (d) {
    var raw = String((d.data.branding && d.data.branding.iceServers) || '').trim();
    var list = [];
    try { list = JSON.parse(raw); } catch (e) { list = []; }
    var good = (Array.isArray(list) ? list : []).filter(function (it) {
      var u = it && it.urls;
      if (typeof u === 'string') return /^(stun|turn|turns):/i.test(u);
      if (Object.prototype.toString.call(u) === '[object Array]') {
        return u.some(function (x) { return /^(stun|turn|turns):/i.test(String(x)); });
      }
      return false;
    });
    var servers = good.length ? good : DEFAULT;
    if (location.hostname) {
      servers.push({
        urls: ['turn:' + location.hostname + ':3478?transport=tcp', 'turn:' + location.hostname + ':3478?transport=udp'],
        username: 'chris', credential: 'chris1234'
      });
    }
    show('cfg', '后台配置：<code>' + (raw || '(空，用默认)') + '</code><br>实际使用：<code>' + JSON.stringify(servers) + '</code>');

    /* 两种配置都试：
       ① 后台配的那套（App 用的就是它）
       ② 只走 TURN over TCP（这台服务器 UDP 被封，TCP 才是能用的那条）
       每次结果都自动报给服务器，手机打开这一页就算自检完成 */
    var tcpOnly = [{ urls: ['turn:' + location.hostname + ':3478?transport=tcp'],
                     username: 'chris', credential: 'chris1234' }];
    var report = [];
    function gather(name, cfg, done) {
      var pc = new RTCPeerConnection({ iceServers: cfg });
      pc.createDataChannel('t');
      var seen = [], states = [];
      pc.onicecandidate = function (e) {
        if (!e.candidate) return;
        var c = e.candidate;
        seen.push(c.type + ' ' + (c.address || '') + ':' + c.port + ' ' + c.protocol);
      };
      pc.onicegatheringstatechange = function () { states.push(pc.iceGatheringState); };
      pc.createOffer().then(function (o) { return pc.setLocalDescription(o); }).catch(function (e) {
        show('res', '<span class="bad">创建连接失败：' + e + '</span>');
      });
      setTimeout(function () {
        var relay = seen.filter(function (x) { return x.indexOf('relay') === 0; }).length;
        var srflx = seen.filter(function (x) { return x.indexOf('srflx') === 0; }).length;
        var gathering = pc.iceGatheringState;
        report.push({ name: name, gathering: gathering, relay: relay, srflx: srflx, cands: seen.slice(0, 8) });
        try { pc.close(); } catch (e) { }
        done();
      }, 9000);
    }
    gather('后台配置', servers, function () {
      gather('只走TURN-TCP', tcpOnly, function () {
        var a = report[0], b = report[1];
        show('cand', report.map(function (r) {
          return '<b>' + r.name + '</b>：gathering=' + r.gathering + ' relay=' + r.relay + ' srflx=' + r.srflx
            + '<br>' + (r.cands.join('<br>') || '(没有候选)');
        }).join('<hr>'));
        var ok = (b.relay > 0) || (a.relay > 0);
        show('res', ok
          ? '<span class="ok">✅ 这台设备能拿到中继候选（TCP 中继 ' + b.relay + ' 条）→ 外网通话这条路是通的</span>'
            + '<br><span class="hint">如果通话还是不通，问题在对方那台设备或 App 版本上，把这一页截图发我，我按上报的日志查。</span>'
          : '<span class="bad">❌ 这台设备连中继候选都拿不到 → 它所在的网络到通话服务器是断的</span>'
            + '<br><span class="hint">把这一页截图发我。</span>');
        /* 自动上报：不用截图我也能看到 */
        try {
          fetch('/api/call-diag', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text: '自检页 ' + (navigator.userAgent || '').slice(0, 40)
              + ' 后台配置=' + JSON.stringify(a) + ' TCP=' + JSON.stringify(b) })
          });
        } catch (e) { }
      });
    });
  }).catch(function (e) { show('res', '<span class="bad">读取配置失败：' + e + '</span>'); });
})();
