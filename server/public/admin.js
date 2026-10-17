(function () {
  'use strict';

  var API = '/api/admin';
  var $ = function (id) { return document.getElementById(id); };
  var state = {
    tab: 'users', users: [], moments: [], chats: [], announcements: [],
    filter: '', branding: null, draft: null, uploadTarget: null,
    plusItems: [], plusIcons: [], plusActions: [], plusDefaults: [],
    gifts: [], giftIcons: [], giftCats: [], giftDefaults: [],
    stickerPacks: [], stickerDefaults: [], stickerTp: { provider: 'off', apiKey: '', urlTemplate: '', limit: 24 },
    statusCats: [], statusDefaults: []
  };
  var ICON_SLOTS = [
    { key: 'chats', label: '消息' },
    { key: 'contacts', label: '联系人' },
    { key: 'groups', label: '群聊' },
    { key: 'moments', label: '朋友圈' },
    { key: 'account', label: '账号' }
  ];
  /* ＋ 面板：图标和动作的中文说法（下拉框里给非技术用户看） */
  var PLUS_ICON_NAMES = {
    photo: '图片', camera: '相机', video: '摄像机', location: '定位', redpacket: '红包',
    gift: '礼物', transfer: '转账箭头', voice: '麦克风', favorite: '五角星', card: '名片',
    file: '文件', music: '音符', coupon: '卡券', chain: '链接', vote: '柱状图',
    screen: '屏幕', star: '星星', heart: '爱心', link: '连接环', none: '无图标'
  };
  var PLUS_ACTION_NAMES = {
    photo: '选照片并发送', camera: '拍摄并发送', videocall: '视频通话', location: '发送位置',
    redpacket: '发送红包', gift: '发送礼物', transfer: '发起转账', voice: '语音输入',
    favorite: '收藏', card: '发送名片', file: '选择文件并发送', music: '分享音乐',
    coupon: '分享卡券', none: '不做事（只显示）'
  };
  var toastTimer = null;

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
          var err = new Error(body.error || ('请求失败 ' + res.status));
          err.status = res.status;
          if (res.status === 401) showLogin('登录状态已失效，请重新登录');
          throw err;
        }
        return body.data;
      });
    });
  }

  function toast(message, tone) {
    var node = $('toast');
    node.textContent = message;
    node.setAttribute('data-tone', tone || '');
    node.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { node.hidden = true; }, 2600);
  }

  function bytes(n) {
    if (!n) return '0 B';
    var units = ['B', 'KB', 'MB', 'GB'];
    var i = 0;
    var v = n;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
    return v.toFixed(i === 0 ? 0 : 1) + ' ' + units[i];
  }

  function duration(seconds) {
    var s = Math.max(0, Math.floor(seconds));
    var d = Math.floor(s / 86400);
    var h = Math.floor((s % 86400) / 3600);
    var m = Math.floor((s % 3600) / 60);
    if (d) return d + ' 天 ' + h + ' 小时';
    if (h) return h + ' 小时 ' + m + ' 分';
    return m + ' 分 ' + (s % 60) + ' 秒';
  }

  function time(iso) {
    var d = new Date(iso);
    if (isNaN(d.getTime())) return '';
    return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' +
      String(d.getDate()).padStart(2, '0') + ' ' + String(d.getHours()).padStart(2, '0') + ':' +
      String(d.getMinutes()).padStart(2, '0');
  }

  /* ------------------------------------------------------------- 登录 */

  function showLogin(message) {
    $('adminShell').hidden = true;
    $('loginGate').hidden = false;
    var err = $('loginError');
    err.hidden = !message;
    err.textContent = message || '';
    setTimeout(function () { $('loginPassword').focus(); }, 60);
  }

  function showApp() {
    $('loginGate').hidden = true;
    $('adminShell').hidden = false;
    loadAll();
  }

  function submitLogin(e) {
    e.preventDefault();
    var password = $('loginPassword').value.trim();
    if (!password) return showLogin('请输入管理员密码');
    var btn = $('loginBtn');
    btn.disabled = true;
    fetch(API + '/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ password: password })
    }).then(function (r) {
      return r.json().then(function (body) {
        if (!r.ok || body.ok === false) throw new Error(body.error || '登录失败');
        showApp();
      });
    }).catch(function (err) {
      showLogin(err.message);
    }).then(function () { btn.disabled = false; });
  }

  /* ------------------------------------------------------------- 渲染 */

  function renderStats(s) {
    var items = [
      { label: '注册用户', value: s.users },
      { label: '当前在线', value: s.online },
      { label: '已禁用', value: s.banned },
      { label: '好友关系', value: s.friends },
      { label: '会话', value: s.chats },
      { label: '消息', value: s.messages },
      { label: '动态', value: s.moments },
      { label: '存储占用', value: bytes(s.storageBytes) }
    ];
    $('stats').innerHTML = items.map(function (i) {
      return '<div class="stat"><div class="stat-label">' + esc(i.label) +
        '</div><div class="stat-value">' + esc(i.value) + '</div></div>';
    }).join('');
  }

  function renderUsers() {
    var q = state.filter.toLowerCase();
    var list = state.users.filter(function (u) {
      return !q || u.username.toLowerCase().includes(q) || u.nickname.toLowerCase().includes(q);
    });
    $('userEmpty').hidden = list.length > 0;
    $('userRows').innerHTML = list.map(function (u) {
      return '<tr>' +
        '<td><div class="user-cell">' +
          '<div class="avatar">' + (u.avatar ? '<img src="' + esc(u.avatar) + '" alt="">' : esc(initials(u.nickname))) + '</div>' +
          '<div><div class="user-name">' + esc(u.nickname) + '</div>' +
          '<div class="user-sub">@' + esc(u.username) + '</div></div>' +
        '</div></td>' +
        '<td><div class="rn-cell">' +
          '<input class="rn-input" type="text" maxlength="24" placeholder="未设置" value="' + esc(u.realName || '') + '" data-rn-input="' + esc(u.id) + '">' +
          '<div class="rn-actions">' +
            '<button class="mini" data-rn-save="' + esc(u.id) + '">保存</button>' +
            '<button class="mini ' + (u.realNameHidden ? '' : 'warn') + '" data-rn-hide="' + esc(u.id) + '" data-next="' + (u.realNameHidden ? '0' : '1') + '">' +
              (u.realNameHidden ? '脱敏显示' : '实名全显') + '</button>' +
          '</div>' +
          '<div class="rn-preview">转账页显示：' + (u.realName ? esc('（' + (u.realNameMask || '') + '）') : '（未填实名，不显示）') + '</div>' +
        '</div></td>' +
        '<td><button class="mini gender-btn-admin" data-gender="' + esc(u.id) + '" title="点一下切换性别">' +
          (u.gender === 'female' ? '♀ 女' : (u.gender === 'male' ? '♂ 男' : '未设置')) + '</button></td>' +
        '<td><span class="pill ' + (u.banned ? 'pill-banned' : 'pill-ok') + '">' +
          (u.banned ? '已禁用' : '正常') + '</span>' +
          (u.online && !u.banned ? '<span class="pill pill-online">在线</span>' : '') + '</td>' +
        '<td><div class="bal-cell">' +
          '<div class="bal-now">¥' + (Number(u.balance) || 0).toFixed(2) + '</div>' +
          '<div class="rn-actions">' +
            '<input class="rn-input bal-input" type="number" min="0" step="0.01" value="100" data-bal-input="' + esc(u.id) + '">' +
            '<button class="mini" data-bal-add="' + esc(u.id) + '">充值</button>' +
          '</div>' +
        '</div></td>' +
        '<td><div class="bal-cell">' +
          '<div class="bal-now">' + (Number(u.transferLimit) > 0 ? '¥' + (Number(u.transferLimit)).toFixed(2) : '不限') + '</div>' +
          '<div class="rn-actions">' +
            '<input class="rn-input bal-input" type="number" min="0" step="1" value="' + (Number(u.transferLimit) || 0) + '" data-limit-input="' + esc(u.id) + '">' +
            '<button class="mini" data-limit-save="' + esc(u.id) + '">保存</button>' +
          '</div>' +
          '<div class="rn-preview">填 0 = 不限</div>' +
        '</div></td>' +
        '<td class="num">' + u.friendCount + '</td>' +
        '<td class="num">' + u.momentCount + '</td>' +
        '<td class="num">' + u.chatCount + '</td>' +
        '<td>' + time(u.createdAt) + '</td>' +
        '<td class="num"><div class="row-actions">' +
          '<button class="mini ' + (u.banned ? '' : 'warn') + '" data-ban="' + esc(u.id) + '" data-next="' + (u.banned ? '0' : '1') + '">' +
            (u.banned ? '解禁' : '禁用') + '</button>' +
          '<button class="mini" data-reset="' + esc(u.id) + '" data-name="' + esc(u.username) + '">重置密码</button>' +
          '<button class="mini danger" data-del="' + esc(u.id) + '" data-name="' + esc(u.nickname) + '">删除</button>' +
        '</div></td>' +
      '</tr>';
    }).join('');
  }

  function renderMoments() {
    $('momentCount').textContent = '共 ' + state.moments.length + ' 条';
    $('momentEmpty').hidden = state.moments.length > 0;
    $('momentRows').innerHTML = state.moments.map(function (m) {
      var author = m.author || { nickname: '已注销用户' };
      return '<div class="moment-item">' +
        '<div class="avatar">' + (author.avatar ? '<img src="' + esc(author.avatar) + '" alt="">' : esc(initials(author.nickname))) + '</div>' +
        '<div class="moment-body">' +
          '<div class="user-name">' + esc(author.nickname) + '</div>' +
          '<div class="moment-text">' + (m.content ? esc(m.content) : '<span class="hint">（仅图片）</span>') + '</div>' +
          (m.images && m.images.length
            ? '<div class="moment-thumbs">' + m.images.map(function (src) {
              return '<img src="' + esc(src) + '" alt="">';
            }).join('') + '</div>'
            : '') +
          '<div class="moment-meta"><span>' + time(m.createdAt) + '</span>' +
            '<span>♥ ' + m.likes + '</span><span>评论 ' + m.comments + '</span></div>' +
        '</div>' +
        '<div class="row-actions"><button class="mini danger" data-del-moment="' + esc(m.id) + '">删除</button></div>' +
      '</div>';
    }).join('');
  }

  function renderChats() {
    $('chatCount').textContent = '共 ' + state.chats.length + ' 个';
    $('chatEmpty').hidden = state.chats.length > 0;
    $('chatRows').innerHTML = state.chats.map(function (c) {
      var names = (c.members || []).map(function (m) { return m ? m.nickname : '已注销'; }).join('、');
      return '<tr>' +
        '<td>' + (c.type === 'group' ? '群聊' + (c.name ? '「' + esc(c.name) + '」' : '') : '单聊') + '</td>' +
        '<td>' + esc(names || '—') + '</td>' +
        '<td class="num">' + c.messageCount + '</td>' +
        '<td>' + (c.lastMessage ? esc(c.lastMessage.preview) + '<div class="user-sub">' + time(c.lastMessage.createdAt) + '</div>' : '—') + '</td>' +
        '<td class="num"><button class="mini" data-view-chat="' + esc(c.id) + '">查看消息</button></td>' +
      '</tr>';
    }).join('');
  }

  function renderAnnouncements() {
    if (!state.announcements.length) {
      $('announcementList').innerHTML = '<p class="empty">还没有发过公告</p>';
      return;
    }
    $('announcementList').innerHTML = state.announcements.map(function (a) {
      return '<div class="moment-item"><div class="moment-body">' +
        '<div class="moment-text">' + esc(a.content) + '</div>' +
        '<div class="moment-meta"><span>' + time(a.createdAt) + '</span><span>送达 ' + a.chats + ' 个会话</span></div>' +
        '</div></div>';
    }).join('');
  }

  function renderSystem(info) {
    var rows = [
      ['Node 版本', info.node],
      ['运行平台', info.platform],
      ['已运行', duration(info.uptimeSeconds)],
      ['启动时间', time(info.startedAt)],
      ['内存占用', info.memoryMB + ' MB'],
      ['数据目录', info.dataDir]
    ];
    $('systemInfo').innerHTML = rows.map(function (r) {
      return '<div class="kv-row"><div class="kv-key">' + esc(r[0]) + '</div><div class="kv-val">' + esc(r[1]) + '</div></div>';
    }).join('');
  }

  /* ---------------------------------------------------------- 界面图标 */

  function previewInner(value) {
    if (!value) return '<span>默认</span>';
    if (value === 'auto') return '<span class="auto-bg-chip">跟随系统</span>';
    return '<img src="' + esc(value) + '" alt="">';
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


  function updateFontPreview() {
    var box = $('fontPreview');
    if (!box) return;
    var fam = (state.draft.fontFamily || '').trim();
    var styleEl = document.getElementById('brand-font-preview-style');
    if (!styleEl) {
      styleEl = document.createElement('style');
      styleEl.id = 'brand-font-preview-style';
      document.head.appendChild(styleEl);
    }
    if (state.draft.fontUrl) {
      styleEl.textContent = '@font-face{font-family:"CHRIS Custom UI";src:url("' + state.draft.fontUrl + '");font-display:swap;}';
      box.style.fontFamily = '"CHRIS Custom UI"' + (fam ? ', ' + fam : '');
    } else {
      styleEl.textContent = '';
      box.style.fontFamily = fam || '';
    }
  }

  function renderFontFields() {
    var preset = $('fontPreset');
    var custom = $('fontCustom');
    if (!preset || !custom) return;
    var fam = (state.draft.fontFamily || '').trim();
    var matched = null;
    Array.prototype.forEach.call(preset.options, function (o) {
      if (o.value !== 'custom' && o.value === fam) matched = o.value;
    });
    if (!fam) { preset.value = ''; custom.value = ''; custom.disabled = true; }
    else if (matched) { preset.value = matched; custom.value = ''; custom.disabled = true; }
    else { preset.value = 'custom'; custom.value = fam; custom.disabled = false; }
    $('fontFileLabel').textContent = state.draft.fontUrl
      ? ('已上传：' + (state.draft.fontName || '自定义字体'))
      : '未上传字体文件';
    updateFontPreview();
  }

  var ACCENT_PRESETS = [
    { color: '', name: '默认' },
    { color: '#0099ff', name: 'QQ 蓝' },
    { color: '#07c160', name: '微信绿' },
    { color: '#7c5cff', name: '紫罗兰' },
    { color: '#ff5a5f', name: '珊瑚红' },
    { color: '#ff8a00', name: '落日橙' },
    { color: '#00b3a4', name: '青碧' },
    { color: '#ff4d94', name: '樱粉' },
    { color: '#2f3542', name: '深空灰' }
  ];

  var INK_PRESETS = [
    { color: '', name: '默认' },
    { color: '#0f1115', name: '墨黑' },
    { color: '#000000', name: '纯黑' },
    { color: '#333a45', name: '深灰' },
    { color: '#1e293b', name: '石板蓝' },
    { color: '#43302b', name: '暖褐' }
  ];

  function hexRgb(hex) {
    var m = /^#([0-9a-f]{6})$/i.exec(String(hex || '').trim());
    if (!m) return null;
    var n = parseInt(m[1], 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }

  function ratio(hex, against) {
    var a = hexRgb(hex), b = hexRgb(against);
    if (!a || !b) return null;
    function f(v) { v = v / 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
    var la = 0.2126 * f(a[0]) + 0.7152 * f(a[1]) + 0.0722 * f(a[2]);
    var lb = 0.2126 * f(b[0]) + 0.7152 * f(b[1]) + 0.0722 * f(b[2]);
    var hi = Math.max(la, lb), lo = Math.min(la, lb);
    return Math.round(((hi + 0.05) / (lo + 0.05)) * 10) / 10;
  }

  function renderSwatches(containerId, presets, current, attr) {
    var box = $(containerId);
    if (!box) return;
    var cur = String(current || '').toLowerCase();
    box.innerHTML = presets.map(function (p) {
      var active = String(p.color || '').toLowerCase() === cur ? ' is-active' : '';
      if (!p.color) {
        return '<button type="button" class="swatch swatch-none' + active + '" data-' + attr + '="" title="跟随默认">' + esc(p.name) + '</button>';
      }
      return '<button type="button" class="swatch' + active + '" data-' + attr + '="' + p.color + '" title="' + esc(p.name) + '" style="background:' + p.color + '"></button>';
    }).join('');
  }

  function updateThemePreview() {
    var accent = String(state.draft.accentColor || '').trim();
    var ink = String(state.draft.textColor || '').trim();
    var acc = accent || '#0099ff';
    var bubble = $('tpBubble'), btn = $('tpBtn'), text = $('tpText'), preview = $('themePreview');
    if (!bubble || !btn || !text) return;
    var onAccent = (ratio(acc, '#ffffff') !== null && ratio(acc, '#ffffff') < 2.0) ? '#12141a' : '#ffffff';
    bubble.style.background = acc;
    bubble.style.color = onAccent;
    btn.style.background = acc;
    btn.style.color = onAccent;
    text.style.color = ink || '';
    var scale = Number(state.draft.fontScale) || 1;
    if (preview) preview.style.fontSize = (13.5 * scale).toFixed(1) + 'px';
    var fontPreview = $('fontPreview');
    if (fontPreview) fontPreview.style.fontSize = (16 * scale).toFixed(1) + 'px';
    var notes = [];
    if (accent && ratio(accent, '#ffffff') !== null && ratio(accent, '#ffffff') < 2.0) {
      notes.push('主色太浅了，气泡和按钮上的文字会自动换成深色字，保证看得清。');
    }
    if (ink) {
      var r = ratio(ink, '#ffffff');
      if (r !== null && r < 4.5) notes.push('文字颜色和白色背景的对比度只有 ' + r + ':1（建议 4.5:1 以上），太浅会看不清。');
      else if (r !== null) notes.push('文字颜色对比度 ' + r + ':1，清晰。');
    }
    $('colorHint').textContent = notes.join(' ');
  }

  function renderColorFields() {
    var scale = Number(state.draft.fontScale) || 1;
    var sel = $('fontScale'), custom = $('fontScaleCustom');
    if (sel) {
      var matched = Array.prototype.some.call(sel.options, function (o) { return Math.abs(parseFloat(o.value) - scale) < 0.001; });
      sel.value = matched ? String(scale) : '1';
    }
    if (custom) custom.value = (sel && Math.abs(parseFloat(sel.value) - scale) < 0.001) ? '' : String(scale);
    renderSwatches('accentSwatches', ACCENT_PRESETS, state.draft.accentColor, 'accent');
    renderSwatches('textSwatches', INK_PRESETS, state.draft.textColor, 'ink');
    var ap = $('accentPick'), tp = $('textPick');
    if (ap) ap.value = String(state.draft.accentColor || '').trim() || '#0099ff';
    if (tp) tp.value = String(state.draft.textColor || '').trim() || '#0f1115';
    updateThemePreview();
  }

  function renderBranding() {
    if (!state.draft) {
      state.draft = { appName: 'CHRIS Chat', logo: '', icons: {} };
    }
    if (!state.draft.icons) state.draft.icons = {};
    $('brandName').value = state.draft.appName || '';
    if ($('iceServers')) $('iceServers').value = state.draft.iceServers || '';
    var logoBox = $('iconPreview-logo');
    if (logoBox) logoBox.innerHTML = previewInner(state.draft.logo);
    var bgBox = $('iconPreview-chatbg');
    if (bgBox) bgBox.innerHTML = previewInner(state.draft.chatBackground);
    $('iconGrid').innerHTML = ICON_SLOTS.map(function (slot) {
      var value = state.draft.icons[slot.key] || '';
      return '<div class="icon-slot">' +
        '<div class="icon-preview" id="iconPreview-' + slot.key + '">' + previewInner(value) + '</div>' +
        '<div class="icon-name">' + esc(slot.label) + '</div>' +
        '<div class="icon-actions">' +
          '<button class="mini" data-upload="' + slot.key + '">上传</button>' +
          '<button class="mini danger" data-clear="' + slot.key + '">清除</button>' +
        '</div></div>';
    }).join('');
    renderFontFields();
    renderColorFields();
    applyCustomFont(state.branding || state.draft);
  }

  /* ------------------------------------------------------------- 数据 */

  /* ＋ 面板：名称 / 图标 / 动作 / 开关 / 顺序 */
  function plusOptions(list, current, names) {
    return list.map(function (k) {
      return '<option value="' + esc(k) + '"' + (k === current ? ' selected' : '') + '>' + esc(names[k] || k) + '</option>';
    }).join('');
  }

  function renderPlusPanel() {
    var box = $('plusRows');
    if (!box) return;
    box.innerHTML = state.plusItems.map(function (it, i) {
      return '<tr data-i="' + i + '">' +
        '<td class="num"><div class="plus-ord">' +
          '<button class="mini" data-plus="up" title="上移">↑</button>' +
          '<button class="mini" data-plus="down" title="下移">↓</button>' +
        '</div></td>' +
        '<td><input class="plus-input" data-plus="label" maxlength="12" value="' + esc(it.label) + '"></td>' +
        '<td><select class="plus-select" data-plus="icon">' + plusOptions(state.plusIcons, it.icon, PLUS_ICON_NAMES) + '</select></td>' +
        '<td><select class="plus-select" data-plus="action">' + plusOptions(state.plusActions, it.action, PLUS_ACTION_NAMES) + '</select></td>' +
        '<td class="num"><input type="checkbox" data-plus="enabled"' + (it.enabled ? ' checked' : '') + '></td>' +
        '<td class="num"><div class="plus-ord">' +
          '<button class="mini" data-plus="clone">复制</button>' +
          '<button class="mini danger" data-plus="del">删除</button>' +
        '</div></td>' +
      '</tr>';
    }).join('');
    if ($('plusEmpty')) $('plusEmpty').hidden = !!state.plusItems.length;
    if ($('plusHint')) {
      var on = state.plusItems.filter(function (x) { return x.enabled; }).length;
      $('plusHint').textContent = '共 ' + state.plusItems.length + ' 项，其中启用 ' + on + ' 项 → 前台上是 '
        + Math.max(1, Math.ceil(on / 8)) + ' 页（每页 8 个）';
    }
  }

  function loadPlusPanel() {
    return api('/plus-panel').then(function (d) {
      state.plusItems = (d.items || []).map(function (x) { return Object.assign({}, x); });
      state.plusIcons = d.icons || [];
      state.plusActions = d.actions || [];
      state.plusDefaults = d.defaults || [];
      renderPlusPanel();
    }).catch(function (err) { toast(err.message, 'error'); });
  }

  function movePlus(i, dir) {
    var j = i + dir;
    if (j < 0 || j >= state.plusItems.length) return;
    var tmp = state.plusItems[i];
    state.plusItems[i] = state.plusItems[j];
    state.plusItems[j] = tmp;
    renderPlusPanel();
  }

  /* ------------------------------------------------------------- 礼物 */
  function renderGifts() {
    var box = $('giftRows');
    if (!box) return;
    box.innerHTML = state.gifts.map(function (g, i) {
      return '<tr data-g="' + i + '">' +
        '<td class="num"><div class="plus-ord">' +
          '<button class="mini" data-gift="up" title="上移">↑</button>' +
          '<button class="mini" data-gift="down" title="下移">↓</button>' +
        '</div></td>' +
        '<td><input class="plus-input" data-gift="name" maxlength="12" value="' + esc(g.name) + '"></td>' +
        '<td><div class="gift-icon-cell">' +
          '<input class="plus-input gift-icon-input" data-gift="icon" maxlength="8" value="' + esc(g.icon) + '">' +
          '<select class="plus-select gift-icon-pick" data-gift="iconpick"><option value="">预设…</option>' +
            state.giftIcons.map(function (e) { return '<option value="' + esc(e) + '">' + esc(e) + '</option>'; }).join('') +
          '</select>' +
        '</div></td>' +
        '<td class="num"><input class="plus-input" type="number" min="0" max="999999" step="1" data-gift="price" value="' + esc(g.price) + '"></td>' +
        '<td><input class="plus-input" data-gift="category" maxlength="8" list="giftCats" value="' + esc(g.category) + '"></td>' +
        '<td class="num"><input type="checkbox" data-gift="enabled"' + (g.enabled ? ' checked' : '') + '></td>' +
        '<td class="num"><div class="plus-ord">' +
          '<button class="mini" data-gift="clone">复制</button>' +
          '<button class="mini danger" data-gift="del">删除</button>' +
        '</div></td>' +
      '</tr>';
    }).join('');
    if ($('giftEmpty')) $('giftEmpty').hidden = !!state.gifts.length;
    if ($('giftCats')) {
      $('giftCats').innerHTML = state.giftCats.map(function (c) { return '<option value="' + esc(c) + '"></option>'; }).join('');
    }
    if ($('giftHint')) {
      var on = state.gifts.filter(function (x) { return x.enabled; }).length;
      var cats = {};
      state.gifts.forEach(function (x) { if (x.enabled) cats[x.category] = 1; });
      $('giftHint').textContent = '共 ' + state.gifts.length + ' 个礼物，上架 ' + on + ' 个，分 ' + Object.keys(cats).length + ' 类 → 前台礼物面板 '
        + Math.max(1, Math.ceil(on / 8)) + ' 页（每页 8 个）';
    }
  }

  /* ------------------------------------------------------------- 表情包 */
  function renderStickers() {
    var box = $('stickerRows');
    if (!box) return;
    box.innerHTML = state.stickerPacks.map(function (p, i) {
      return '<tr data-s="' + i + '">' +
        '<td class="num"><div class="plus-ord">' +
          '<button class="mini" data-sticker="up" title="上移">↑</button>' +
          '<button class="mini" data-sticker="down" title="下移">↓</button>' +
        '</div></td>' +
        '<td><input class="plus-input" data-sticker="name" maxlength="12" value="' + esc(p.name) + '"></td>' +
        '<td><input class="plus-input gift-icon-input" data-sticker="icon" maxlength="8" value="' + esc(p.icon) + '"></td>' +
        '<td class="num"><input type="checkbox" data-sticker="enabled"' + (p.enabled ? ' checked' : '') + '></td>' +
        '<td><textarea class="plus-input sticker-list" data-sticker="stickers" rows="3">' + esc((p.stickers || []).join('\n')) + '</textarea></td>' +
        '<td class="num"><div class="plus-ord">' +
          '<button class="mini" data-sticker="clone">复制</button>' +
          '<button class="mini danger" data-sticker="del">删除</button>' +
        '</div></td>' +
      '</tr>';
    }).join('');
    if ($('stickerEmpty')) $('stickerEmpty').hidden = !!state.stickerPacks.length;

    var tp = state.stickerTp || {};
    if ($('tpProvider')) $('tpProvider').value = tp.provider || 'off';
    if ($('tpKey')) $('tpKey').value = tp.apiKey || '';
    if ($('tpUrl')) $('tpUrl').value = tp.urlTemplate || '';
    if ($('tpLimit')) $('tpLimit').value = tp.limit || 24;
    var on = state.stickerPacks.filter(function (x) { return x.enabled; });
    var count = on.reduce(function (a, p) { return a + (p.stickers || []).length; }, 0);
    if ($('tpHint')) {
      $('tpHint').textContent = '共 ' + state.stickerPacks.length + ' 个表情包 / 上架 ' + on.length + ' 个 / 表情 ' + count + ' 个 · '
        + '第三方：' + ({ off: '关闭', tenor: 'Tenor', giphy: 'Giphy', custom: '自定义接口' }[(tp.provider || 'off')] || '关闭');
    }
  }

  /* ------------------------------------------------------------- 状态 */
  function statusLines(items) {
    return (items || []).map(function (it) {
      return (it.icon || '🙂') + ' ' + (it.label || '') + (it.color ? ' ' + it.color : '') + (it.color2 ? ' ' + it.color2 : '');
    }).join('\n');
  }

  function parseStatusLines(text) {
    return String(text || '').split('\n').map(function (line, i) {
      var s = line.trim();
      if (!s) return null;
      var parts = s.split(/\s+/);
      var icon = parts.shift() || '🙂';
      var colors = parts.filter(function (x) { return /^#[0-9a-f]{6}$/i.test(x); });
      var label = parts.filter(function (x) { return colors.indexOf(x) < 0; }).join(' ') || '状态';
      return {
        id: 's' + (i + 1) + '_' + Date.now().toString(36),
        icon: icon, label: label,
        color: colors[0] || '', color2: colors[1] || ''
      };
    }).filter(Boolean);
  }

  function renderStatuses() {
    var box = $('statusRows');
    if (!box) return;
    box.innerHTML = state.statusCats.map(function (c, i) {
      return '<tr data-st="' + i + '">' +
        '<td class="num"><div class="plus-ord">' +
          '<button class="mini" data-stcat="up">↑</button><button class="mini" data-stcat="down">↓</button>' +
        '</div></td>' +
        '<td><input class="plus-input" data-stcat="name" maxlength="12" value="' + esc(c.name) + '"></td>' +
        '<td><input class="plus-input gift-icon-input" data-stcat="color" maxlength="7" value="' + esc(c.color || '#6f8a38') + '"></td>' +
        '<td class="num"><input type="checkbox" data-stcat="enabled"' + (c.enabled ? ' checked' : '') + '></td>' +
        '<td><textarea class="plus-input sticker-list" data-stcat="items" rows="3">' + esc(statusLines(c.items)) + '</textarea></td>' +
        '<td class="num"><div class="plus-ord">' +
          '<button class="mini" data-stcat="clone">复制</button><button class="mini danger" data-stcat="del">删除</button>' +
        '</div></td>' +
      '</tr>';
    }).join('');
    if ($('statusEmpty')) $('statusEmpty').hidden = !!state.statusCats.length;
    if ($('statusHint')) {
      var on = state.statusCats.filter(function (c) { return c.enabled; });
      var n = on.reduce(function (a, c) { return a + (c.items || []).length; }, 0);
      $('statusHint').textContent = '共 ' + state.statusCats.length + ' 个分类 / 上架 ' + on.length + ' 个 / 状态 ' + n + ' 个 · '
        + '接口：GET /api/statuses（前台取）、GET/PUT /api/admin/statuses（本页读写）';
    }
  }

  function readThirdPartyForm() {
    return {
      provider: $('tpProvider') ? $('tpProvider').value : 'off',
      apiKey: $('tpKey') ? $('tpKey').value.trim() : '',
      urlTemplate: $('tpUrl') ? $('tpUrl').value.trim() : '',
      limit: $('tpLimit') ? Number($('tpLimit').value) || 24 : 24
    };
  }

  function moveGift(i, dir) {
    var j = i + dir;
    if (j < 0 || j >= state.gifts.length) return;
    var tmp = state.gifts[i];
    state.gifts[i] = state.gifts[j];
    state.gifts[j] = tmp;
    renderGifts();
  }

  function loadAll() {
    return Promise.all([
      api('/stats'), api('/users?pageSize=100'), api('/moments?pageSize=50'),
      api('/chats?pageSize=50'), api('/announcements'), api('/system'), api('/branding'),
      api('/plus-panel'), api('/gifts'), api('/stickers'), api('/statuses')
    ]).then(function (r) {
      renderStats(r[0]);
      state.users = r[1].users || [];
      state.moments = r[2].moments || [];
      state.chats = r[3].chats || [];
      state.announcements = r[4].announcements || [];
      state.branding = (r[6] && r[6].branding) || {};
      state.draft = JSON.parse(JSON.stringify(state.branding));
      state.plusItems = ((r[7] && r[7].items) || []).map(function (x) { return Object.assign({}, x); });
      state.plusIcons = (r[7] && r[7].icons) || [];
      state.plusActions = (r[7] && r[7].actions) || [];
      state.plusDefaults = (r[7] && r[7].defaults) || [];
      state.gifts = ((r[8] && r[8].gifts) || []).map(function (x) { return Object.assign({}, x); });
      state.giftIcons = (r[8] && r[8].icons) || [];
      state.giftCats = (r[8] && r[8].categories) || [];
      state.giftDefaults = (r[8] && r[8].defaults) || [];
      state.stickerPacks = ((r[9] && r[9].packs) || []).map(function (x) { return Object.assign({}, x, { stickers: (x.stickers || []).slice() }); });
      state.stickerDefaults = (r[9] && r[9].defaults) || [];
      state.stickerTp = Object.assign({ provider: 'off', apiKey: '', urlTemplate: '', limit: 24 }, (r[9] && r[9].thirdParty) || {});
      state.statusCats = ((r[10] && r[10].categories) || []).map(function (c) { return Object.assign({}, c, { items: (c.items || []).slice() }); });
      state.statusDefaults = (r[10] && r[10].defaults) || [];
      if (!state.draft.icons) state.draft.icons = {};
      applyCustomFont(state.branding);
      renderUsers(); renderMoments(); renderChats(); renderAnnouncements(); renderSystem(r[5]);
      renderBranding();
      renderPlusPanel();
      renderGifts();
      renderStickers();
      renderStatuses();
      $('connState').textContent = '已登录 · 数据实时来自服务端';
      $('connState').setAttribute('data-tone', 'ok');
    }).catch(function (err) {
      $('connState').textContent = '加载失败：' + err.message;
      $('connState').setAttribute('data-tone', 'error');
    });
  }

  function switchTab(tab) {
    state.tab = tab;
    document.querySelectorAll('.tab').forEach(function (t) {
      t.classList.toggle('is-active', t.getAttribute('data-tab') === tab);
    });
    document.querySelectorAll('[data-panel]').forEach(function (p) {
      p.hidden = p.getAttribute('data-panel') !== tab;
    });
  }

  function openModal(title, html) {
    $('modalTitle').textContent = title;
    $('modalBody').innerHTML = html;
    $('modalMask').hidden = false;
  }

  function closeModal() { $('modalMask').hidden = true; }

  function viewChat(chatId) {
    api('/messages?chatId=' + encodeURIComponent(chatId) + '&limit=100').then(function (data) {
      var title = data.chat.type === 'group'
        ? '群聊「' + data.chat.name + '」'
        : (data.chat.members || []).map(function (m) { return m.nickname; }).join(' ↔ ');
      var body = data.messages.length
        ? data.messages.map(function (m) {
          return '<div class="chat-line">' +
            '<div class="who">' + esc(m.senderName) + '</div>' +
            '<div class="what">' + (m.recalled ? '<span class="hint">[已撤回]</span>'
              : (m.kind === 'image' ? '<img src="' + esc(m.content) + '" style="max-width:180px;border-radius:8px">'
                : (m.kind === 'system' ? '<span class="hint">' + esc(m.content) + '</span>' : esc(m.content)))) + '</div>' +
            '<div class="when">' + time(m.createdAt) + '</div>' +
          '</div>';
        }).join('')
        : '<p class="empty">这个会话还没有消息</p>';
      openModal(title, body);
    }).catch(function (err) { toast(err.message, 'error'); });
  }

  /* ------------------------------------------------------------- 交互 */

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

  function setupEvents() {
    $('loginForm').addEventListener('submit', submitLogin);
    $('pwToggle').addEventListener('click', function () {
      var input = $('loginPassword');
      var show = input.type === 'password';
      input.type = show ? 'text' : 'password';
      // 按钮里现在是图标，不再改文字，避免把 svg 抹掉
      this.classList.toggle('is-on', show);
      this.title = show ? '隐藏密码' : '显示密码';
      input.focus();
    });

    $('logoutBtn').addEventListener('click', function () {
      api('/logout', { method: 'POST' }).catch(function () {}).then(function () {
        showLogin('');
      });
    });
    $('refreshBtn').addEventListener('click', function () {
      loadAll();
      toast('已刷新');
    });

    document.querySelectorAll('.tab').forEach(function (t) {
      t.addEventListener('click', function () { switchTab(t.getAttribute('data-tab')); });
    });

    $('userSearch').addEventListener('input', function () {
      state.filter = this.value.trim();
      renderUsers();
    });

    $('userRows').addEventListener('click', function (e) {
      var ban = e.target.closest('[data-ban]');
      var reset = e.target.closest('[data-reset]');
      var del = e.target.closest('[data-del]');
      var gen = e.target.closest('[data-gender]');
      var rnSave = e.target.closest('[data-rn-save]');
      var rnHide = e.target.closest('[data-rn-hide]');
      var balAdd = e.target.closest('[data-bal-add]');
      var limitSave = e.target.closest('[data-limit-save]');
      if (limitSave) {
        var lid = limitSave.getAttribute('data-limit-save');
        var lin = document.querySelector('[data-limit-input="' + lid + '"]');
        var lim = Number(lin ? lin.value : 0);
        api('/users/' + encodeURIComponent(lid), { method: 'PATCH', body: JSON.stringify({ transferLimit: lim }) })
          .then(function () {
            toast(lim > 0 ? ('单笔转账限额已设为 ¥' + lim.toFixed(2)) : '已设为不限额度');
            loadAll();
          })
          .catch(function (err) { toast(err.message, 'error'); });
        return;
      }
      if (balAdd) {
        var bid = balAdd.getAttribute('data-bal-add');
        var input = document.querySelector('[data-bal-input="' + bid + '"]');
        var amount = Number(input ? input.value : 0);
        if (!(amount > 0)) { toast('充值金额要大于 0', 'error'); return; }
        api('/users/' + encodeURIComponent(bid) + '/recharge', { method: 'POST', body: JSON.stringify({ amount: amount }) })
          .then(function (d) {
            toast('已充值 ¥' + Number(d.recharged).toFixed(2) + '，余额 ¥' + Number(d.balance).toFixed(2));
            loadAll();
          })
          .catch(function (err) { toast(err.message, 'error'); });
        return;
      }
      if (rnSave || rnHide) {
        var uid = (rnSave || rnHide).getAttribute(rnSave ? 'data-rn-save' : 'data-rn-hide');
        var payload = {};
        if (rnSave) {
          var box = document.querySelector('[data-rn-input="' + uid + '"]');
          payload.realName = box ? box.value.trim() : '';
        } else {
          payload.realNameHidden = rnHide.getAttribute('data-next') === '1';
        }
        api('/users/' + encodeURIComponent(uid), { method: 'PATCH', body: JSON.stringify(payload) })
          .then(function () {
            toast(rnSave ? (payload.realName ? '实名已保存：' + payload.realName : '已清空实名') : (payload.realNameHidden ? '已改为脱敏显示' : '已改为实名全显'));
            loadAll();
          })
          .catch(function (err) { toast(err.message, 'error'); });
        return;
      }
      if (gen) {
        var cur = gen.textContent.indexOf('女') >= 0 ? 'female' : (gen.textContent.indexOf('男') >= 0 ? 'male' : '');
        var nextGender = cur === 'female' ? 'male' : 'female';
        api('/users/' + encodeURIComponent(gen.getAttribute('data-gender')), {
          method: 'PATCH', body: JSON.stringify({ gender: nextGender })
        }).then(function () {
          toast('性别已改为「' + (nextGender === 'female' ? '女' : '男') + '」');
          loadAll();
        }).catch(function (err) { toast(err.message, 'error'); });
        return;
      }
      if (ban) {
        var next = ban.getAttribute('data-next') === '1';
        api('/users/' + encodeURIComponent(ban.getAttribute('data-ban')), {
          method: 'PATCH', body: JSON.stringify({ banned: next })
        }).then(function () {
          toast(next ? '已禁用该账号' : '已解禁');
          loadAll();
        }).catch(function (err) { toast(err.message, 'error'); });
      } else if (reset) {
        var pwd = window.prompt('给「' + reset.getAttribute('data-name') + '」设置新密码（至少 6 位）：');
        if (!pwd) return;
        api('/users/' + encodeURIComponent(reset.getAttribute('data-reset')), {
          method: 'PATCH', body: JSON.stringify({ password: pwd })
        }).then(function () { toast('密码已重置'); })
          .catch(function (err) { toast(err.message, 'error'); });
      } else if (del) {
        if (!window.confirm('确定删除用户「' + del.getAttribute('data-name') + '」？\n他的好友关系、动态、单聊会话都会被一并删除，不可恢复。')) return;
        api('/users/' + encodeURIComponent(del.getAttribute('data-del')), { method: 'DELETE' })
          .then(function () { toast('用户已删除'); loadAll(); })
          .catch(function (err) { toast(err.message, 'error'); });
      }
    });

    $('momentRows').addEventListener('click', function (e) {
      var del = e.target.closest('[data-del-moment]');
      if (!del) return;
      if (!window.confirm('删除这条动态？对方的界面会实时移除。')) return;
      api('/moments/' + encodeURIComponent(del.getAttribute('data-del-moment')), { method: 'DELETE' })
        .then(function () { toast('动态已删除'); loadAll(); })
        .catch(function (err) { toast(err.message, 'error'); });
    });

    $('chatRows').addEventListener('click', function (e) {
      var view = e.target.closest('[data-view-chat]');
      if (view) viewChat(view.getAttribute('data-view-chat'));
    });

    $('broadcastBtn').addEventListener('click', function () {
      var text = $('broadcastText').value.trim();
      if (!text) return toast('请输入公告内容', 'error');
      var btn = this;
      btn.disabled = true;
      api('/broadcast', { method: 'POST', body: JSON.stringify({ content: text }) })
        .then(function (data) {
          $('broadcastText').value = '';
          toast('公告已推送到 ' + data.announcement.chats + ' 个会话');
          loadAll();
        })
        .catch(function (err) { toast(err.message, 'error'); })
        .then(function () { btn.disabled = false; });
    });

    document.querySelector('[data-panel="branding"]').addEventListener('click', function (e) {
      var up = e.target.closest('[data-upload]');
      var cl = e.target.closest('[data-clear]');
      if (up) {
        var target = up.getAttribute('data-upload');
        if (target === 'font') { $('fontFile').click(); return; }
        state.uploadTarget = target;
        $('iconFile').click();
        return;
      }
      var auto = e.target.closest('[data-auto]');
      if (auto) {
        var akey = auto.getAttribute('data-auto');
        if (akey === 'chatBackground') {
          state.draft.chatBackground = 'auto';
          renderBranding();
          toast('已设为跟随系统，记得点「保存并推送」');
        }
        return;
      }
      if (cl) {
        var key = cl.getAttribute('data-clear');
        if (key === 'font') {
          state.draft.fontUrl = '';
          state.draft.fontName = '';
          renderFontFields();
          toast('已清除字体文件，记得保存');
          return;
        }
        if (key === 'logo') state.draft.logo = '';
        else if (key === 'chatBackground') state.draft.chatBackground = '';
        else state.draft.icons[key] = '';
        renderBranding();
      }
    });

    $('fontPreset').addEventListener('change', function () {
      if (this.value === 'custom') {
        $('fontCustom').disabled = false;
        state.draft.fontFamily = $('fontCustom').value.trim();
        $('fontCustom').focus();
      } else {
        $('fontCustom').disabled = true;
        $('fontCustom').value = '';
        state.draft.fontFamily = this.value;
      }
      updateFontPreview();
    });

    $('fontCustom').addEventListener('input', function () {
      state.draft.fontFamily = this.value.trim();
      updateFontPreview();
    });

    $('fontFile').addEventListener('change', function (e) {
      var file = e.target.files && e.target.files[0];
      e.target.value = '';
      if (!file) return;
      if (file.size > 15 * 1024 * 1024) return toast('字体文件建议不超过 15MB', 'error');
      var reader = new FileReader();
      reader.onload = function () {
        api('/upload', { method: 'POST', body: JSON.stringify({ dataUrl: String(reader.result), filename: file.name }) })
          .then(function (d) {
            state.draft.fontUrl = d.url;
            state.draft.fontName = file.name;
            renderFontFields();
            toast('字体已上传，点「保存并推送」生效');
          })
          .catch(function (err) { toast(err.message, 'error'); });
      };
      reader.readAsDataURL(file);
    });


    $('fontScale').addEventListener('change', function () {
      state.draft.fontScale = parseFloat(this.value) || 1;
      $('fontScaleCustom').value = '';
      updateThemePreview();
    });

    $('fontScaleCustom').addEventListener('input', function () {
      var v = parseFloat(this.value);
      if (!isFinite(v)) { state.draft.fontScale = parseFloat($('fontScale').value) || 1; updateThemePreview(); return; }
      state.draft.fontScale = Math.min(1.4, Math.max(0.8, Math.round(v * 100) / 100));
      updateThemePreview();
    });

    $('accentSwatches').addEventListener('click', function (e) {
      var b = e.target.closest('[data-accent]');
      if (!b) return;
      state.draft.accentColor = b.getAttribute('data-accent');
      renderColorFields();
    });

    $('textSwatches').addEventListener('click', function (e) {
      var b = e.target.closest('[data-ink]');
      if (!b) return;
      state.draft.textColor = b.getAttribute('data-ink');
      renderColorFields();
    });

    $('accentPick').addEventListener('input', function () {
      state.draft.accentColor = this.value;
      renderSwatches('accentSwatches', ACCENT_PRESETS, state.draft.accentColor, 'accent');
      updateThemePreview();
    });

    $('textPick').addEventListener('input', function () {
      state.draft.textColor = this.value;
      renderSwatches('textSwatches', INK_PRESETS, state.draft.textColor, 'ink');
      updateThemePreview();
    });

    $('iconFile').addEventListener('change', function (e) {
      var file = e.target.files && e.target.files[0];
      var key = state.uploadTarget;
      e.target.value = '';
      if (!file || !key) return;
      if (file.size > 2 * 1024 * 1024) return toast('图标建议不超过 2MB', 'error');
      var reader = new FileReader();
      reader.onload = function () {
        api('/upload', {
          method: 'POST',
          body: JSON.stringify({ dataUrl: String(reader.result), filename: file.name })
        }).then(function (d) {
          if (key === 'logo') state.draft.logo = d.url;
          else if (key === 'chatBackground') state.draft.chatBackground = d.url;
          else state.draft.icons[key] = d.url;
          renderBranding();
          toast('已选择图片，点「保存并推送」生效');
        }).catch(function (err) { toast(err.message, 'error'); });
      };
      reader.readAsDataURL(file);
    });

    $('saveBrandingBtn').addEventListener('click', function () {
      var btn = this;
      btn.disabled = true;
      state.draft.appName = $('brandName').value.trim() || 'CHRIS Chat';
      if ($('iceServers')) state.draft.iceServers = $('iceServers').value.trim();
      var customScale = parseFloat($('fontScaleCustom').value);
      var scale = isFinite(customScale) ? customScale : parseFloat($('fontScale').value);
      if (!isFinite(scale)) scale = 1;
      state.draft.fontScale = Math.min(1.4, Math.max(0.8, Math.round(scale * 100) / 100));
      api('/branding', { method: 'PUT', body: JSON.stringify(state.draft) })
        .then(function (data) {
          state.branding = data.branding;
          state.draft = JSON.parse(JSON.stringify(data.branding));
          renderBranding();
          toast('已保存，在线用户界面已实时更新');
        })
        .catch(function (err) { toast(err.message, 'error'); })
        .then(function () { btn.disabled = false; });
    });

    $('resetBrandingBtn').addEventListener('click', function () {
      if (!window.confirm('把应用名和所有图标恢复成默认？记得再点一次「保存并推送」。')) return;
      state.draft = {
        appName: 'CHRIS Chat', logo: '', chatBackground: '',
        fontFamily: '', fontName: '', fontUrl: '',
        fontScale: 1, accentColor: '', textColor: '', iceServers: '',
        icons: { chats: '', contacts: '', groups: '', moments: '', account: '' }
      };
      renderBranding();
      toast('已恢复默认，点「保存并推送」生效');
    });

    /* ---------- ＋ 面板：行内改名 / 换图标 / 换动作 / 排序 / 启停 ---------- */
    if ($('plusRows')) {
      var plusRow = function (el) {
        var tr = el.closest('tr'); if (!tr) return -1;
        return Number(tr.getAttribute('data-i'));
      };
      $('plusRows').addEventListener('input', function (e) {
        var el = e.target.closest('[data-plus]'); if (!el) return;
        var it = state.plusItems[plusRow(el)]; if (!it) return;
        var kind = el.getAttribute('data-plus');
        if (kind === 'label') it.label = el.value;
        else if (kind === 'icon') it.icon = el.value;
        else if (kind === 'action') it.action = el.value;
      });
      $('plusRows').addEventListener('change', function (e) {
        var el = e.target.closest('[data-plus="enabled"]'); if (!el) return;
        var it = state.plusItems[plusRow(el)]; if (!it) return;
        it.enabled = !!el.checked;
        renderPlusPanel();
      });
      $('plusRows').addEventListener('click', function (e) {
        var btn = e.target.closest('[data-plus]'); if (!btn) return;
        var kind = btn.getAttribute('data-plus');
        if (kind === 'label' || kind === 'icon' || kind === 'action' || kind === 'enabled') return;
        var i = plusRow(btn); if (i < 0) return;
        if (kind === 'up') movePlus(i, -1);
        else if (kind === 'down') movePlus(i, 1);
        else if (kind === 'del') { state.plusItems.splice(i, 1); renderPlusPanel(); }
        else if (kind === 'clone') {
          state.plusItems.splice(i + 1, 0, Object.assign({}, state.plusItems[i]));
          renderPlusPanel();
        }
      });
    }

    if ($('plusAddBtn')) {
      $('plusAddBtn').addEventListener('click', function () {
        state.plusItems.push({
          id: 'p' + Date.now().toString(36),
          label: '新功能', icon: state.plusIcons[0] || 'star', action: 'none', enabled: true
        });
        renderPlusPanel();
        var first = document.querySelector('#plusRows tr:last-child .plus-input');
        if (first) first.focus();
      });
    }

    if ($('plusSaveBtn')) {
      $('plusSaveBtn').addEventListener('click', function () {
        var btn = this;
        btn.disabled = true;
        api('/plus-panel', { method: 'PUT', body: JSON.stringify({ items: state.plusItems }) })
          .then(function (data) {
            state.plusItems = (data.items || []).map(function (x) { return Object.assign({}, x); });
            renderPlusPanel();
            toast('已保存，「＋」面板在线上立刻生效（在线用户不用刷新）');
          })
          .catch(function (err) { toast(err.message, 'error'); })
          .then(function () { btn.disabled = false; });
      });
    }

    if ($('plusResetBtn')) {
      $('plusResetBtn').addEventListener('click', function () {
        if (!window.confirm('恢复成默认（微信那 8 个 + 常用几项）？记得再点一次「保存并推送」。')) return;
        state.plusItems = state.plusDefaults.map(function (x) { return Object.assign({}, x); });
        renderPlusPanel();
        toast('已恢复默认，点「保存并推送」生效');
      });
    }

    /* ---------- 礼物：加礼物 / 改名 / 换图标 / 定价 / 分类 / 上下架 ---------- */
    if ($('giftRows')) {
      var giftRow = function (el) {
        var tr = el.closest('tr'); if (!tr) return -1;
        return Number(tr.getAttribute('data-g'));
      };
      $('giftRows').addEventListener('input', function (e) {
        var el = e.target.closest('[data-gift]'); if (!el) return;
        var g = state.gifts[giftRow(el)]; if (!g) return;
        var kind = el.getAttribute('data-gift');
        if (kind === 'name') g.name = el.value;
        else if (kind === 'icon') g.icon = el.value;
        else if (kind === 'price') g.price = Number(el.value) || 0;
        else if (kind === 'category') g.category = el.value;
      });
      $('giftRows').addEventListener('change', function (e) {
        var pick = e.target.closest('[data-gift="iconpick"]');
        if (pick) {
          var gg = state.gifts[giftRow(pick)];
          if (gg && pick.value) {
            gg.icon = pick.value;
            var input = pick.closest('tr').querySelector('[data-gift="icon"]');
            if (input) input.value = pick.value;
          }
          pick.value = '';
          return;
        }
        var box = e.target.closest('[data-gift="enabled"]');
        if (box) {
          var g2 = state.gifts[giftRow(box)];
          if (g2) { g2.enabled = !!box.checked; renderGifts(); }
        }
      });
      $('giftRows').addEventListener('click', function (e) {
        var btn = e.target.closest('[data-gift]'); if (!btn) return;
        var kind = btn.getAttribute('data-gift');
        if (kind === 'name' || kind === 'icon' || kind === 'price' || kind === 'category' || kind === 'enabled' || kind === 'iconpick') return;
        var i = giftRow(btn); if (i < 0) return;
        if (kind === 'up') moveGift(i, -1);
        else if (kind === 'down') moveGift(i, 1);
        else if (kind === 'del') { state.gifts.splice(i, 1); renderGifts(); }
        else if (kind === 'clone') {
          state.gifts.splice(i + 1, 0, Object.assign({}, state.gifts[i]));
          renderGifts();
        }
      });
    }

    if ($('giftAddBtn')) {
      $('giftAddBtn').addEventListener('click', function () {
        state.gifts.push({
          id: 'g' + Date.now().toString(36),
          name: '新礼物', icon: '🎁', price: 1, category: '通用', enabled: true
        });
        renderGifts();
        var first = document.querySelector('#giftRows tr:last-child [data-gift="name"]');
        if (first) { first.focus(); first.select(); }
      });
    }

    if ($('giftSaveBtn')) {
      $('giftSaveBtn').addEventListener('click', function () {
        var btn = this;
        btn.disabled = true;
        api('/gifts', { method: 'PUT', body: JSON.stringify({ gifts: state.gifts }) })
          .then(function (data) {
            state.gifts = (data.gifts || []).map(function (x) { return Object.assign({}, x); });
            renderGifts();
            toast('礼物已保存，前台上立刻能选到（在线用户不用刷新）');
          })
          .catch(function (err) { toast(err.message, 'error'); })
          .then(function () { btn.disabled = false; });
      });
    }

    if ($('giftResetBtn')) {
      $('giftResetBtn').addEventListener('click', function () {
        if (!window.confirm('恢复成默认那 16 个礼物？记得再点一次「保存并推送」。')) return;
        state.gifts = state.giftDefaults.map(function (x) { return Object.assign({}, x); });
        renderGifts();
        toast('已恢复默认礼物，点「保存并推送」生效');
      });
    }

    /* ---------- 表情包：本地表情包 + 第三方图源（默认不接） ---------- */
    if ($('stickerRows')) {
      var sRow = function (el) {
        var tr = el.closest('tr'); if (!tr) return -1;
        return Number(tr.getAttribute('data-s'));
      };
      $('stickerRows').addEventListener('input', function (e) {
        var el = e.target.closest('[data-sticker]'); if (!el) return;
        var p = state.stickerPacks[sRow(el)]; if (!p) return;
        var kind = el.getAttribute('data-sticker');
        if (kind === 'name') p.name = el.value;
        else if (kind === 'icon') p.icon = el.value;
        else if (kind === 'stickers') p.stickers = el.value.split('\n').map(function (x) { return x.trim(); }).filter(Boolean);
      });
      $('stickerRows').addEventListener('change', function (e) {
        var el = e.target.closest('[data-sticker="enabled"]'); if (!el) return;
        var p = state.stickerPacks[sRow(el)]; if (!p) return;
        p.enabled = !!el.checked;
        renderStickers();
      });
      $('stickerRows').addEventListener('click', function (e) {
        var btn = e.target.closest('[data-sticker]'); if (!btn) return;
        var kind = btn.getAttribute('data-sticker');
        if (kind === 'name' || kind === 'icon' || kind === 'enabled' || kind === 'stickers') return;
        var i = sRow(btn); if (i < 0) return;
        var swap = function (a, b) { var t = state.stickerPacks[a]; state.stickerPacks[a] = state.stickerPacks[b]; state.stickerPacks[b] = t; renderStickers(); };
        if (kind === 'up' && i > 0) swap(i, i - 1);
        else if (kind === 'down' && i < state.stickerPacks.length - 1) swap(i, i + 1);
        else if (kind === 'del') { state.stickerPacks.splice(i, 1); renderStickers(); }
        else if (kind === 'clone') {
          state.stickerPacks.splice(i + 1, 0, Object.assign({}, state.stickerPacks[i], { stickers: (state.stickerPacks[i].stickers || []).slice() }));
          renderStickers();
        }
      });
    }

    if ($('stickerAddBtn')) {
      $('stickerAddBtn').addEventListener('click', function () {
        state.stickerPacks.push({ id: 's' + Date.now().toString(36), name: '新表情包', icon: '🙂', enabled: true, stickers: ['🙂', '😄', '😭'] });
        renderStickers();
        var first = document.querySelector('#stickerRows tr:last-child [data-sticker="name"]');
        if (first) { first.focus(); first.select(); }
      });
    }

    if ($('stickerSaveBtn')) {
      $('stickerSaveBtn').addEventListener('click', function () {
        var btn = this;
        btn.disabled = true;
        api('/stickers', { method: 'PUT', body: JSON.stringify({ packs: state.stickerPacks, thirdParty: readThirdPartyForm() }) })
          .then(function (data) {
            state.stickerPacks = (data.packs || []).map(function (x) { return Object.assign({}, x, { stickers: (x.stickers || []).slice() }); });
            state.stickerTp = Object.assign({}, data.thirdParty);
            renderStickers();
            toast('表情包已保存，前台上立刻生效');
          })
          .catch(function (err) { toast(err.message, 'error'); })
          .then(function () { btn.disabled = false; });
      });
    }

    if ($('stickerResetBtn')) {
      $('stickerResetBtn').addEventListener('click', function () {
        if (!window.confirm('恢复成默认的 5 个表情包？记得再点「保存并推送」。')) return;
        state.stickerPacks = state.stickerDefaults.map(function (x) { return Object.assign({}, x, { stickers: (x.stickers || []).slice() }); });
        renderStickers();
        toast('已恢复默认表情包，点「保存并推送」生效');
      });
    }

    if ($('tpSaveBtn')) {
      $('tpSaveBtn').addEventListener('click', function () {
        var btn = this;
        btn.disabled = true;
        api('/stickers', { method: 'PUT', body: JSON.stringify({ packs: state.stickerPacks, thirdParty: readThirdPartyForm() }) })
          .then(function (data) {
            state.stickerTp = Object.assign({}, data.thirdParty);
            renderStickers();
            toast(state.stickerTp.provider === 'off' ? '已保存：第三方关闭，只用本地表情包' : '第三方设置已保存');
          })
          .catch(function (err) { toast(err.message, 'error'); })
          .then(function () { btn.disabled = false; });
      });
    }

    if ($('tpTestBtn')) {
      $('tpTestBtn').addEventListener('click', function () {
        var btn = this;
        btn.disabled = true;
        api('/stickers/test?q=' + encodeURIComponent('开心'))
          .then(function (d) {
            if (d && d.error) { toast(d.error, 'error'); return; }
            toast('通了：返回 ' + ((d && d.items) || []).length + ' 个（HTTP ' + (d && d.status) + '）');
          })
          .catch(function (err) { toast(err.message, 'error'); })
          .then(function () { btn.disabled = false; });
      });
    }

    /* ---------- 状态：分类 + 每个状态 ---------- */
    if ($('statusRows')) {
      var stRow = function (el) {
        var tr = el.closest('tr'); if (!tr) return -1;
        return Number(tr.getAttribute('data-st'));
      };
      $('statusRows').addEventListener('input', function (e) {
        var el = e.target.closest('[data-stcat]'); if (!el) return;
        var c = state.statusCats[stRow(el)]; if (!c) return;
        var kind = el.getAttribute('data-stcat');
        if (kind === 'name') c.name = el.value;
        else if (kind === 'color') c.color = el.value;
        else if (kind === 'items') c.items = parseStatusLines(el.value);
      });
      $('statusRows').addEventListener('change', function (e) {
        var el = e.target.closest('[data-stcat="enabled"]'); if (!el) return;
        var c = state.statusCats[stRow(el)]; if (!c) return;
        c.enabled = !!el.checked;
        renderStatuses();
      });
      $('statusRows').addEventListener('click', function (e) {
        var btn = e.target.closest('[data-stcat]'); if (!btn) return;
        var kind = btn.getAttribute('data-stcat');
        if (kind === 'name' || kind === 'color' || kind === 'enabled' || kind === 'items') return;
        var i = stRow(btn); if (i < 0) return;
        var swap = function (a, b) { var t = state.statusCats[a]; state.statusCats[a] = state.statusCats[b]; state.statusCats[b] = t; renderStatuses(); };
        if (kind === 'up' && i > 0) swap(i, i - 1);
        else if (kind === 'down' && i < state.statusCats.length - 1) swap(i, i + 1);
        else if (kind === 'del') { state.statusCats.splice(i, 1); renderStatuses(); }
        else if (kind === 'clone') {
          state.statusCats.splice(i + 1, 0, Object.assign({}, state.statusCats[i], { items: (state.statusCats[i].items || []).slice() }));
          renderStatuses();
        }
      });
    }

    if ($('statusAddBtn')) {
      $('statusAddBtn').addEventListener('click', function () {
        state.statusCats.push({ id: 'c' + Date.now().toString(36), name: '新分类', color: '#6f8a38', enabled: true, items: [{ id: 'n1', icon: '🙂', label: '新状态' }] });
        renderStatuses();
      });
    }

    if ($('statusSaveBtn')) {
      $('statusSaveBtn').addEventListener('click', function () {
        var btn = this;
        btn.disabled = true;
        api('/statuses', { method: 'PUT', body: JSON.stringify({ categories: state.statusCats }) })
          .then(function (data) {
            state.statusCats = (data.categories || []).map(function (c) { return Object.assign({}, c, { items: (c.items || []).slice() }); });
            renderStatuses();
            toast('状态已保存，前台上立刻能用');
          })
          .catch(function (err) { toast(err.message, 'error'); })
          .then(function () { btn.disabled = false; });
      });
    }

    if ($('statusResetBtn')) {
      $('statusResetBtn').addEventListener('click', function () {
        if (!window.confirm('恢复成默认 4 个分类 / 24 个状态？记得再点「保存并推送」。')) return;
        state.statusCats = state.statusDefaults.map(function (c) { return Object.assign({}, c, { items: (c.items || []).slice() }); });
        renderStatuses();
        toast('已恢复默认，点「保存并推送」生效');
      });
    }

    $('modalClose').addEventListener('click', closeModal);
    $('modalMask').addEventListener('click', function (e) {
      if (e.target === $('modalMask')) closeModal();
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') closeModal();
    });
  }

  /* ------------------------------------------------ 界面自动更新检测 */

  // 后台开着不动时，前端文件更新了就在切回来的时候自动刷新一次
  function startVersionWatch() {
    var known = null;
    function check() {
      return fetch('/api/version', { headers: { Accept: 'application/json' } })
        .then(function (r) { return r.json(); })
        .then(function (data) {
          var v = data && data.data && data.data.version;
          if (!v) return;
          if (!known) { known = v; return; }
          if (v === known && !document.hidden) return;
          if (v !== known && document.hidden) { location.reload(); return; }
          if (v !== known) toast('后台界面已更新，刷新页面生效');
        })
        .catch(function () { /* 忽略 */ });
    }
    setInterval(check, 20000);
    document.addEventListener('visibilitychange', function () { if (!document.hidden) check(); });
    setTimeout(check, 3000);
  }

  setupEvents();
  setupTheme();
  startVersionWatch();
  api('/session').then(function (data) {
    if (data.authenticated) showApp();
    else showLogin('');
  }).catch(function (err) {
    // 有 status 说明服务是通的、只是这次请求被拒（api() 里已经提示过了），
    // 只有真正连不上（网络错误）才提示去检查后端
    if (err && err.status) return;
    showLogin('连不上服务，请确认后端已启动');
  });
})();
