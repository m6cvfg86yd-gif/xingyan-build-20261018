/* 新版后台：照参考后台（一对一视频社交）的结构做 —— 左侧分组菜单 + 数据总览 + 列表页 */
(function () {
  'use strict';
  var API = '/api/admin';
  var $ = function (id) { return document.getElementById(id); };
  var state = { nav: [], page: 'dash', pageNo: 1, filters: {}, rows: null, brand: null, collapsed: {}, tableDef: null };

  function esc(v) {
    return String(v == null ? '' : v).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  function api(path, opts) {
    var o = opts || {};
    return fetch(API + path, {
      method: o.method || 'GET',
      headers: o.body ? { 'content-type': 'application/json' } : undefined,
      body: o.body ? JSON.stringify(o.body) : undefined,
      credentials: 'same-origin'
    }).then(function (r) {
      return r.json().then(function (j) {
        if (!r.ok) throw new Error((j && j.error) || ('HTTP ' + r.status));
        return j && j.data !== undefined ? j.data : j;
      });
    });
  }
  var toastTimer = null;
  function toast(msg) {
    var el = $('cmfToast');
    el.textContent = msg; el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.hidden = true; }, 2200);
  }

  /* ------------------------------------------------ 菜单 */
  function renderMenu() {
    var html = '';
    state.nav.forEach(function (item, idx) {
      if (item.children) {
        var open = state.collapsed[item.text] === true || item.children.some(function (c) { return c.key === state.page; });
        html += '<div class="cmf-group' + (open ? ' open' : '') + '">' +
          '<button class="cmf-group-title" data-group="' + esc(item.text) + '">' + esc(item.text) + '<i>' + (open ? '▾' : '▸') + '</i></button><div class="cmf-group-body">';
        item.children.forEach(function (c) {
          html += '<button class="cmf-menu-item' + (c.key === state.page ? ' active' : '') + '" data-key="' + esc(c.key) + '">' + esc(c.text) + '</button>';
        });
        html += '</div></div>';
      } else {
        html += '<button class="cmf-menu-item top' + (item.key === state.page ? ' active' : '') + '" data-key="' + esc(item.key) + '">' + esc(item.text) + '</button>';
      }
    });
    $('cmfMenu').innerHTML = html;
  }
  $('cmfMenu').addEventListener('click', function (e) {
    var g = e.target.closest('[data-group]');
    if (g) { state.collapsed[g.getAttribute('data-group')] = !state.collapsed[g.getAttribute('data-group')]; renderMenu(); return; }
    var it = e.target.closest('[data-key]');
    if (it) { state.page = it.getAttribute('data-key'); state.pageNo = 1; state.filters = {}; renderMenu(); render(); }
  });
  function crumbText() {
    for (var i = 0; i < state.nav.length; i++) {
      var it = state.nav[i];
      if (it.key === state.page) return it.text;
      if (it.children) for (var j = 0; j < it.children.length; j++) if (it.children[j].key === state.page) return it.text + ' / ' + it.children[j].text;
    }
    return '数据总览';
  }

  /* ------------------------------------------------ 总览 */
  function renderDash(d) {
    var html = '<div class="cmf-cards">';
    (d.groups || []).forEach(function (g) {
      html += '<div class="cmf-card-group"><div class="cmf-card-title">' + esc(g.title) + '</div><div class="cmf-card-row">';
      g.items.forEach(function (it) {
        html += '<div class="cmf-card"><div class="cmf-card-label">' + esc(it.label) + '</div><div class="cmf-card-value">' + esc(it.value) + '</div>' +
          (it.sub ? '<div class="cmf-card-sub">' + esc(it.sub) + '</div>' : '') +
          (it.sub2 ? '<div class="cmf-card-sub">' + esc(it.sub2) + '</div>' : '') +
          (it.total ? '<div class="cmf-card-total">' + esc(it.total) + '</div>' : '') + '</div>';
      });
      html += '</div></div>';
    });
    html += '</div>';
    html += '<div class="cmf-panel"><div class="cmf-panel-title">最近通话</div><table class="cmf-table"><thead><tr><th>通话类型</th><th>状态</th><th>时长（分钟）</th><th>时间</th></tr></thead><tbody>';
    (d.recentCalls || []).forEach(function (c) {
      var miss = /未接听|已取消|已拒绝|不在线|忙线/.test(c.content);
      html += '<tr><td>' + esc(c.type) + '</td><td>' + (miss ? '<span class="cmf-tag warn">未接通</span>' : '<span class="cmf-tag ok">通话结束</span>') + '</td><td>' + esc(c.mins) + '</td><td>' + esc(String(c.at).slice(0, 19).replace('T', ' ')) + '</td></tr>';
    });
    if (!(d.recentCalls || []).length) html += '<tr><td colspan="4" class="cmf-empty">暂无通话记录</td></tr>';
    html += '</tbody></table></div>';
    $('cmfContent').innerHTML = html;
  }

  /* ------------------------------------------------ 通用列表 */
  var FILTERS = {
    users: [{ k: 'uid', label: '用户ID' }, { k: 'keyword', label: '用户名/昵称/手机' }, { k: 'status', label: '状态', options: [['', '全部'], ['ok', '正常'], ['banned', '已封禁']] }],
    calls: [{ k: 'type', label: '通话类型', options: [['', '全部'], ['video', '视频通话'], ['voice', '语音通话']] }, { k: 'status', label: '通话状态', options: [['', '全部'], ['end', '通话结束'], ['miss', '未接通']] }],
    dynamic: [{ k: 'uid', label: '用户ID' }, { k: 'keyword', label: '关键字' }],
    dynamicpass: [{ k: 'uid', label: '用户ID' }],
    dynamicnopass: [{ k: 'uid', label: '用户ID' }],
    dynamiclower: [{ k: 'uid', label: '用户ID' }],
    callmonitor: [{ k: 'type', label: '通话类型', options: [['', '全部'], ['video', '视频通话'], ['voice', '语音通话']] }]
  };
  function renderTable(d) {
    var f = FILTERS[state.page] || [];
    var html = '<div class="cmf-panel"><div class="cmf-filter">';
    f.forEach(function (x) {
      html += '<label>' + esc(x.label) + '：</label>';
      if (x.options) {
        html += '<select data-filter="' + x.k + '">' + x.options.map(function (o) { return '<option value="' + esc(o[0]) + '"' + ((state.filters[x.k] || '') === o[0] ? ' selected' : '') + '>' + esc(o[1]) + '</option>'; }).join('') + '</select>';
      } else {
        html += '<input data-filter="' + x.k + '" value="' + esc(state.filters[x.k] || '') + '" placeholder="请输入">';
      }
    });
    html += '<button class="cmf-btn" id="cmfSearch">搜索</button><button class="cmf-btn ghost" id="cmfClear">清空</button>';
    html += '</div><table class="cmf-table"><thead><tr>';
    (d.cols || []).forEach(function (c) { html += '<th>' + esc(c) + '</th>'; });
    html += '</tr></thead><tbody>';
    (d.rows || []).forEach(function (r) {
      html += '<tr>';
      (r.cells || []).forEach(function (c, ci) {
        var last = ci === (r.cells.length - 1);
        html += '<td>' + (last ? rowActions(state.page, r) : esc(c)) + '</td>';
      });
      html += '</tr>';
    });
    if (!(d.rows || []).length) html += '<tr><td colspan="' + Math.max(1, (d.cols || []).length) + '" class="cmf-empty">暂无数据</td></tr>';
    html += '</tbody></table><div class="cmf-pager">共 ' + (d.total || 0) + ' 条</div></div>';
    $('cmfContent').innerHTML = html;
  }
  function rowActions(page, r) {
    var id = esc(r.id);
    if (page === 'users') {
      var banned = r.raw && r.raw.banned;
      return '<button class="cmf-btn mini" data-act="' + (banned ? 'unban' : 'ban') + '" data-id="' + id + '">' + (banned ? '解封' : '拉黑') + '</button>' +
        '<button class="cmf-btn mini ghost" data-act="edit" data-id="' + id + '">编辑</button>' +
        '<button class="cmf-btn mini danger" data-act="delete" data-id="' + id + '">删除</button>';
    }
    if (/^dynamic/.test(page)) {
      return '<button class="cmf-btn mini" data-act="pass" data-id="' + id + '">通过</button>' +
        '<button class="cmf-btn mini ghost" data-act="reject" data-id="' + id + '">拒绝</button>' +
        '<button class="cmf-btn mini ghost" data-act="lower" data-id="' + id + '">下架</button>' +
        '<button class="cmf-btn mini danger" data-act="delete" data-id="' + id + '">删除</button>';
    }
    return '<button class="cmf-btn mini ghost" data-act="edit" data-id="' + id + '">编辑</button>' +
      '<button class="cmf-btn mini danger" data-act="delete" data-id="' + id + '">删除</button>';
  }
  document.addEventListener('click', function (e) {
    var b = e.target.closest('[data-act]');
    if (!b) return;
    var act = b.getAttribute('data-act'), id = b.getAttribute('data-id');
    if (act === 'edit') return editRow(id);
    if (act === 'delete' && !confirm('确定删除这一条吗？')) return;
    api('/act', { method: 'POST', body: { dataset: state.page, action: act, id: id } })
      .then(function () { toast('操作成功'); render(); })
      .catch(function (err) { toast(err.message); });
  });
  document.addEventListener('click', function (e) {
    if (e.target.id === 'cmfSearch') { collectFilters(); render(); }
    if (e.target.id === 'cmfClear') { state.filters = {}; render(); }
  });
  function collectFilters() {
    var els = document.querySelectorAll('[data-filter]');
    state.filters = {};
    Array.prototype.forEach.call(els, function (el) { if (el.value) state.filters[el.getAttribute('data-filter')] = el.value; });
  }

  /* ------------------------------------------------ 编辑弹窗 */
  function openModal(title, fields, onOk) {
    $('cmfModalTitle').textContent = title;
    $('cmfModalBody').innerHTML = fields.map(function (f, i) {
      return '<label class="cmf-field"><span>' + esc(f.label) + '</span><input data-i="' + i + '" value="' + esc(f.value || '') + '"></label>';
    }).join('');
    $('cmfModal').hidden = false;
    $('cmfModalOk').onclick = function () {
      var vals = Array.prototype.map.call(document.querySelectorAll('#cmfModalBody input'), function (x) { return x.value; });
      $('cmfModal').hidden = true;
      onOk(vals);
    };
  }
  $('cmfModalClose').onclick = $('cmfModalCancel').onclick = function () { $('cmfModal').hidden = true; };

  function editRow(id) {
    if (state.page === 'users') {
      var row = (state.rows || []).filter(function (r) { return String(r.id) === String(id); })[0] || {};
      openModal('编辑用户', [{ label: '昵称', value: (row.raw || {}).nickname || '' }, { label: '手机号', value: '' }], function (vals) {
        api('/act', { method: 'POST', body: { dataset: 'users', action: 'edit', id: id, nickname: vals[0], phone: vals[1] } })
          .then(function () { toast('已保存'); render(); }).catch(function (e2) { toast(e2.message); });
      });
      return;
    }
    var d = state.tableDef || { cols: [] };
    openModal('编辑', (d.cols || []).map(function (c, i) { return { label: c, value: i === 0 ? id : '' }; }), function (vals) {
      api('/act', { method: 'POST', body: { dataset: state.page, action: 'save', id: id, cells: vals } })
        .then(function () { toast('已保存'); render(); }).catch(function (e3) { toast(e3.message); });
    });
  }

  /* ================= 设置类页面（原「经典后台」的功能搬到这里） ================= */
  var ICON_SLOTS = [
    { key: 'chats', label: '消息' }, { key: 'contacts', label: '联系人' },
    { key: 'groups', label: '群聊' }, { key: 'moments', label: '朋友圈' }, { key: 'account', label: '账号' }
  ];
  var FONT_PRESETS = [
    ['"Segoe UI","Microsoft YaHei UI","Microsoft YaHei",Arial,sans-serif', '微软雅黑 UI（QQ 同款）'],
    ['"Microsoft YaHei",Arial,sans-serif', '微软雅黑'],
    ['"PingFang SC","Microsoft YaHei",sans-serif', '苹方 / 雅黑'],
    ['"Source Han Sans SC","Noto Sans SC","Microsoft YaHei",sans-serif', '思源黑体'],
    ['"SimSun","Songti SC",serif', '宋体'],
    ['"KaiTi","STKaiti",serif', '楷体'],
    ['DIN-Medium,"Microsoft YaHei",sans-serif', 'DIN 数字体 + 雅黑']
  ];
  var ACCENT_PRESETS = ['#0099ff', '#1c86ee', '#0084f0', '#07c160', '#ff6b35', '#8b5cf6', '#e5484d', '#0f9b8e'];
  var TEXT_PRESETS = ['#0f1115', '#1f2937', '#374151', '#4b5563', '#111827'];

  function uploadFile(file) {
    return new Promise(function (resolve, reject) {
      var fr = new FileReader();
      fr.onload = function () {
        api('/upload', { method: 'POST', body: { dataUrl: String(fr.result), filename: file.name } })
          .then(function (d) { resolve(d.url); }).catch(reject);
      };
      fr.onerror = function () { reject(new Error('读取文件失败')); };
      fr.readAsDataURL(file);
    });
  }
  function saveBranding(patch, msg) {
    return api('/branding', { method: 'PUT', body: patch }).then(function (d) {
      if (d && d.branding) state.brand = d.branding;
      toast(msg || '已保存，前台实时生效');
    }).catch(function (e) { toast(e.message); });
  }
  function bindUpload(inputId, handler) {
    var el = $(inputId);
    if (!el) return;
    el.onchange = function (e) {
      var file = e.target.files && e.target.files[0];
      e.target.value = '';
      if (!file) return;
      if (file.size > 15 * 1024 * 1024) return toast('文件别超过 15MB');
      uploadFile(file).then(function (url) { handler(url, file); }).catch(function (err) { toast(err.message); });
    };
  }

  function renderSettings(page) {
    api('/branding').then(function (d) {
      var b = (d && d.branding) || {};
      state.brand = b;
      var c = $('cmfContent');
      if (page === 'site') {
        c.innerHTML = '<div class="cmf-panel"><div class="cmf-panel-title">网站信息</div>' +
          '<label class="cmf-field"><span>应用名称</span><input id="sfName" value="' + esc(b.appName || '') + '"></label>' +
          '<label class="cmf-field"><span>Logo（上传图片或填地址）</span><input id="sfLogo" value="' + esc(b.logo || '') + '" placeholder="可留空"></label>' +
          '<div class="cmf-filter"><input type="file" id="sfLogoFile" accept="image/*"><button class="cmf-btn" id="sfSave">保存并推送</button>' +
          (b.logo ? '<img src="' + esc(b.logo) + '" style="height:34px;border-radius:6px">' : '') + '</div></div>';
        $('sfSave').onclick = function () { saveBranding({ appName: $('sfName').value.trim(), logo: $('sfLogo').value.trim() }); };
        bindUpload('sfLogoFile', function (url) { $('sfLogo').value = url; saveBranding({ logo: url }, 'Logo 已上传并生效'); });
        return;
      }
      if (page === 'ui') {
        var icons = b.icons || {};
        c.innerHTML = '<div class="cmf-panel"><div class="cmf-panel-title">界面图标（左侧竖栏）</div><p class="cmf-hint">上传后前台对应位置的图标立刻换成图片；留空用默认图标。</p><div class="cmf-card-row">' +
          ICON_SLOTS.map(function (s) {
            var v = icons[s.key] || '';
            return '<div class="cmf-card"><div class="cmf-card-label">' + esc(s.label) + '</div>' +
              (v ? '<img src="' + esc(v) + '" style="height:34px;margin:6px 0;border-radius:6px">' : '<div class="cmf-card-sub" style="margin:8px 0">默认图标</div>') +
              '<input type="file" data-icon="' + s.key + '" accept="image/*"><div><button class="cmf-btn mini ghost" data-clear="' + s.key + '">恢复默认</button></div></div>';
          }).join('') + '</div></div>';
        Array.prototype.forEach.call(c.querySelectorAll('[data-icon]'), function (inp) {
          inp.onchange = function (e) {
            var key = inp.getAttribute('data-icon');
            var file = e.target.files && e.target.files[0]; e.target.value = '';
            if (!file) return;
            uploadFile(file).then(function (url) {
              var patch = { icons: {} }; patch.icons[key] = url;
              return saveBranding(patch, '图标已更新').then(function () { renderSettings('ui'); });
            }).catch(function (err) { toast(err.message); });
          };
        });
        Array.prototype.forEach.call(c.querySelectorAll('[data-clear]'), function (btn) {
          btn.onclick = function () {
            var key = btn.getAttribute('data-clear');
            var patch = { icons: {} }; patch.icons[key] = '';
            saveBranding(patch, '已恢复默认图标').then(function () { renderSettings('ui'); });
          };
        });
        return;
      }
      if (page === 'font') {
        c.innerHTML = '<div class="cmf-panel"><div class="cmf-panel-title">字体与字号</div>' +
          '<label class="cmf-field"><span>字体预设</span><select id="ffPreset">' + FONT_PRESETS.map(function (f, i) { return '<option value="' + esc(f[0]) + '"' + ((b.fontFamily || '') === f[0] ? ' selected' : '') + '>' + esc(f[1]) + '</option>'; }).join('') + '</select></label>' +
          '<label class="cmf-field"><span>自定义 font-family</span><input id="ffCustom" value="' + esc(b.fontFamily || '') + '"></label>' +
          '<label class="cmf-field"><span>上传字体文件（ttf / otf / woff / woff2）</span><input type="file" id="ffFile" accept=".ttf,.otf,.woff,.woff2"></label>' +
          '<div class="cmf-hint">当前字体：' + esc(b.fontName || '(系统字体)') + (b.fontUrl ? ' · 已上传' : '') + '</div>' +
          '<label class="cmf-field"><span>字号大小（0.8 ~ 1.4 倍）</span><input id="ffScale" type="range" min="0.8" max="1.4" step="0.02" value="' + esc(b.fontScale || 1) + '"></label>' +
          '<div class="cmf-filter"><span id="ffScaleVal" class="cmf-hint">' + Math.round((b.fontScale || 1) * 100) + '%</span><button class="cmf-btn" id="ffSave">保存并推送</button></div>' +
          '<div class="cmf-card" style="margin-top:12px;font-family:' + esc(b.fontFamily || 'inherit') + '">预览：CHRIS Chat 聊天界面 · 今天天气不错 1234567890</div></div>';
        $('ffPreset').onchange = function () { $('ffCustom').value = $('ffPreset').value; };
        $('ffScale').oninput = function () { $('ffScaleVal').textContent = Math.round(Number($('ffScale').value) * 100) + '%'; };
        $('ffSave').onclick = function () { saveBranding({ fontFamily: $('ffCustom').value.trim() || $('ffPreset').value, fontScale: Number($('ffScale').value) }); };
        bindUpload('ffFile', function (url, file) {
          saveBranding({ fontUrl: url, fontName: file.name }, '字体已上传并生效').then(function () { renderSettings('font'); });
        });
        return;
      }
      if (page === 'theme') {
        c.innerHTML = '<div class="cmf-panel"><div class="cmf-panel-title">界面配色</div>' +
          '<label class="cmf-field"><span>主色调（气泡 / 按钮 / 选中态）</span><input type="color" id="thAccent" value="' + esc(b.accentColor || '#0099ff') + '"></label>' +
          '<div class="cmf-filter">' + ACCENT_PRESETS.map(function (x) { return '<button class="cmf-btn mini" data-accent="' + x + '" style="background:' + x + '">' + x + '</button>'; }).join('') + '</div>' +
          '<label class="cmf-field"><span>文字颜色（浅色模式）</span><input type="color" id="thText" value="' + esc(b.textColor || '#0f1115') + '"></label>' +
          '<div class="cmf-filter">' + TEXT_PRESETS.map(function (x) { return '<button class="cmf-btn mini ghost" data-text="' + x + '">' + x + '</button>'; }).join('') + '</div>' +
          '<div class="cmf-filter"><button class="cmf-btn" id="thSave">保存并推送</button></div></div>';
        Array.prototype.forEach.call(c.querySelectorAll('[data-accent]'), function (btn) { btn.onclick = function () { $('thAccent').value = btn.getAttribute('data-accent'); }; });
        Array.prototype.forEach.call(c.querySelectorAll('[data-text]'), function (btn) { btn.onclick = function () { $('thText').value = btn.getAttribute('data-text'); }; });
        $('thSave').onclick = function () { saveBranding({ accentColor: $('thAccent').value, textColor: $('thText').value }); };
        return;
      }
      if (page === 'chatbg') {
        c.innerHTML = '<div class="cmf-panel"><div class="cmf-panel-title">聊天背景（全局默认）</div><p class="cmf-hint">用户自己也能在「更多 → 聊天背景」里换，这里设的是新用户的默认背景。</p>' +
          '<label class="cmf-field"><span>背景图地址</span><input id="cbUrl" value="' + esc(b.chatBackground || '') + '"></label>' +
          '<div class="cmf-filter"><input type="file" id="cbFile" accept="image/*"><button class="cmf-btn" id="cbSave">保存并推送</button><button class="cmf-btn ghost" id="cbClear">恢复默认</button></div></div>';
        $('cbSave').onclick = function () { saveBranding({ chatBackground: $('cbUrl').value.trim() }); };
        $('cbClear').onclick = function () { saveBranding({ chatBackground: '' }, '已恢复默认背景'); };
        bindUpload('cbFile', function (url) { $('cbUrl').value = url; saveBranding({ chatBackground: url }, '聊天背景已更新'); });
        return;
      }
      if (page === 'ice') {
        c.innerHTML = '<div class="cmf-panel"><div class="cmf-panel-title">通话服务器（ICE / TURN）</div>' +
          '<p class="cmf-hint">语音 / 视频通话用的 STUN、TURN，一行一个。跨网络打不通时在后台填 TURN。</p>' +
          '<textarea id="iceText" class="cmf-textarea" rows="7">' + esc(b.iceServers || '') + '</textarea>' +
          '<div class="cmf-filter"><button class="cmf-btn" id="iceSave">保存</button></div></div>';
        $('iceSave').onclick = function () { saveBranding({ iceServers: $('iceText').value.trim() }); };
        return;
      }
      if (page === 'system') {
        api('/system').then(function (s2) {
          c.innerHTML = '<div class="cmf-panel"><div class="cmf-panel-title">系统信息</div><table class="cmf-table"><tbody>' +
            Object.keys(s2).map(function (k) { return '<tr><td style="width:180px">' + esc(k) + '</td><td>' + esc(s2[k]) + '</td></tr>'; }).join('') +
            '</tbody></table></div>';
        }).catch(function (e) { c.innerHTML = '<div class="cmf-empty">' + esc(e.message) + '</div>'; });
        return;
      }
      // 其余（私密设置 / 幻灯片 / 引导页 / 推荐设置）：沿用结构但暂未接入
      c.innerHTML = '<div class="cmf-panel"><div class="cmf-panel-title">' + esc(crumbText().split(' / ').pop()) + '</div>' +
        '<p class="cmf-hint">这一块（' + esc(page) + '）结构和参考后台一致，但我们前台还没有对应功能，暂未接入。' +
        '需要的话告诉我，我把前台功能一起做出来。</p></div>';
    }).catch(function (e) { $('cmfContent').innerHTML = '<div class="cmf-empty">' + esc(e.message) + '</div>'; });
  }

  /* ---------------- 会话管理 / 系统公告（原经典后台的功能） ---------------- */
  function renderChats() {
    api('/chats?pageSize=50').then(function (d) {
      var rows = (d.chats || []).map(function (c) {
        var title = c.type === 'group' ? (c.name || '(群聊)') : ((c.members || []).map(function (m) { return m.nickname; }).join(' ↔ ') || '(私聊)');
        return '<tr><td>' + esc(c.id) + '</td><td>' + (c.type === 'group' ? '群聊' : '单聊') + '</td><td>' + esc(title) + '</td><td>' + esc((c.members || []).length) + '</td><td>' + esc(c.messageCount) + '</td><td>' + esc(c.lastMessage ? String(c.lastMessage.preview).slice(0, 24) : '') + '</td>' +
          '<td><button class="cmf-btn mini ghost" data-msgs="' + esc(c.id) + '">查看消息</button><button class="cmf-btn mini danger" data-delchat="' + esc(c.id) + '">删除</button></td></tr>';
      }).join('') || '<tr><td colspan="7" class="cmf-empty">暂无会话</td></tr>';
      $('cmfContent').innerHTML = '<div class="cmf-panel"><div class="cmf-panel-title">会话管理（共 ' + (d.chats || []).length + ' 个）</div>' +
        '<table class="cmf-table"><thead><tr><th>会话ID</th><th>类型</th><th>参与者</th><th>人数</th><th>消息数</th><th>最后一条</th><th>操作</th></tr></thead><tbody>' + rows + '</tbody></table></div>';
      Array.prototype.forEach.call(document.querySelectorAll('[data-delchat]'), function (b) {
        b.onclick = function () {
          if (!confirm('删除这个会话？所有人的记录都会没。')) return;
          api('/chats/' + encodeURIComponent(b.getAttribute('data-delchat')), { method: 'DELETE' }).then(function () { toast('已删除'); renderChats(); }).catch(function (e) { toast(e.message); });
        };
      });
      Array.prototype.forEach.call(document.querySelectorAll('[data-msgs]'), function (b) {
        b.onclick = function () {
          var id = b.getAttribute('data-msgs');
          api('/messages?chatId=' + encodeURIComponent(id)).then(function (m) {
            openModal('会话消息（' + (m.messages || []).length + ' 条）', [], function () {});
            $('cmfModalBody').innerHTML = '<div style="max-height:50vh;overflow:auto">' + (m.messages || []).map(function (x) {
              return '<div style="padding:4px 0;border-bottom:1px solid #f0f3f8;font-size:12.5px"><b>' + esc(x.senderId) + '</b> ' + esc(String(x.content).slice(0, 80)) + ' <span style="color:#98a1b0">' + esc(String(x.createdAt).slice(0, 19).replace('T', ' ')) + '</span></div>';
            }).join('') + '</div>';
            $('cmfModalOk').hidden = true;
          }).catch(function (e) { toast(e.message); });
        };
      });
    }).catch(function (e) { $('cmfContent').innerHTML = '<div class="cmf-empty">' + esc(e.message) + '</div>'; });
  }

  function renderBroadcast() {
    $('cmfContent').innerHTML = '<div class="cmf-panel"><div class="cmf-panel-title">发布系统公告</div>' +
      '<textarea id="bcText" class="cmf-textarea" rows="3" placeholder="公告内容，会发到每个人的会话里"></textarea>' +
      '<div class="cmf-filter"><button class="cmf-btn" id="bcSend">发布</button></div></div>' +
      '<div class="cmf-panel"><div class="cmf-panel-title">历史公告</div><div id="bcList" class="cmf-hint">加载中…</div></div>';
    $('bcSend').onclick = function () {
      var text = $('bcText').value.trim();
      if (!text) return toast('公告内容不能为空');
      api('/broadcast', { method: 'POST', body: { content: text } }).then(function (d) {
        toast('已发布，触达 ' + ((d && d.chats) || 0) + ' 个会话');
        $('bcText').value = '';
        renderBroadcast();
      }).catch(function (e) { toast(e.message); });
    };
    api('/announcements').then(function (d) {
      var list = d.announcements || [];
      $('bcList').innerHTML = list.length ? list.map(function (a) {
        return '<div style="padding:8px 0;border-bottom:1px solid #eef2f7"><div>' + esc(a.content || a.text || '') + '</div><div class="cmf-card-sub">' + esc(String(a.createdAt || '').slice(0, 19).replace('T', ' ')) + '</div></div>';
      }).join('') : '还没有发过公告';
    }).catch(function () { $('bcList').textContent = '读取失败'; });
  }

  /* ------------------------------------------------ 渲染入口 */
  function render() {
    $('cmfCrumb').textContent = crumbText();
    var p = state.page;
    if (p === 'dash') { api('/dash').then(renderDash).catch(function (e) { $('cmfContent').innerHTML = '<div class="cmf-empty">' + esc(e.message) + '</div>'; }); return; }
    if (['site', 'ui', 'font', 'theme', 'chatbg', 'ice', 'system', 'configpri', 'slide', 'guide', 'recommend'].indexOf(p) >= 0) { renderSettings(p); return; }
    if (p === 'chats') { renderChats(); return; }
    if (p === 'broadcast') { renderBroadcast(); return; }
    var qs = '?name=' + encodeURIComponent(p) + '&page=' + state.pageNo;
    Object.keys(state.filters).forEach(function (k) { qs += '&' + encodeURIComponent(k) + '=' + encodeURIComponent(state.filters[k]); });
    api('/rows' + qs).then(function (d) {
      state.rows = d.rows; state.tableDef = d;
      if (d.settings) { renderBrand(d.settings); return; }
      renderTable(d);
    }).catch(function (e) { $('cmfContent').innerHTML = '<div class="cmf-empty">' + esc(e.message) + '</div>'; });
  }

  /* ------------------------------------------------ 登录 / 启动 */
  function showLogin() { $('cmfLogin').hidden = false; $('cmfWrap').hidden = true; }
  function boot() {
    api('/session').then(function (d) {
      if (d && d.admin) { $('cmfLogin').hidden = true; $('cmfWrap').hidden = false; start(); }
      else showLogin();
    }).catch(showLogin);
  }
  $('cmfLoginBtn').onclick = function () {
    api('/login', { method: 'POST', body: { password: $('cmfPwd').value } })
      .then(function () { $('cmfLogin').hidden = true; $('cmfWrap').hidden = false; start(); })
      .catch(function (e) { $('cmfLoginTip').textContent = e.message; });
  };
  $('cmfPwd').addEventListener('keydown', function (e) { if (e.key === 'Enter') $('cmfLoginBtn').click(); });
  $('cmfLogout').onclick = function () { api('/logout', { method: 'POST' }).then(function () { location.reload(); }); };
  $('cmfRefresh').onclick = function () { render(); toast('已刷新'); };
  function start() {
    api('/nav').then(function (d) {
      state.nav = d.nav || [];
      // 设置类页面走 branding
      state.nav.forEach(function (it) {
        if (it.children) it.children.forEach(function (c) { if (['site', 'configpri', 'ui', 'ice'].indexOf(c.key) >= 0) c.key = c.key; });
      });
      renderMenu(); render();
    });
  }
  boot();
})();
