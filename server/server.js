'use strict';

/**
 * CHRIS Chat · 零依赖即时通讯服务端
 *
 * HTTP：静态托管 public/，以及 /api 下注册、登录、好友、会话、消息接口
 * WebSocket：lib/ws.js 自实现（RFC 6455），负责实时收发
 * 数据：users/friendships/chats/reads 存 JSON，消息按会话追加到 JSONL
 *
 * 启动：node server.js     默认 http://127.0.0.1:5180
 */

const http = require('http');
const http2 = require('http2');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const os = require('os');
const { spawnSync, spawn } = require('child_process');
const zlib = require('zlib');
const ws = require('./lib/ws');

const ROOT = __dirname;
const PUBLIC_DIR = path.join(ROOT, 'public');
const DATA_DIR = process.env.DATA_DIR ? path.resolve(process.env.DATA_DIR) : path.join(ROOT, 'data');
const MSG_DIR = path.join(DATA_DIR, 'messages');
const UPLOAD_DIR = path.join(DATA_DIR, 'uploads');

const PORT = Number(process.env.PORT || 5180);
/* 内置 TURN（通话中转）的端口和账号：局域网内部用，保持简单 */
const TURN_PORT_NUM = Number(process.env.TURN_PORT || 3478);
const TURN_USER = process.env.TURN_USER || 'chris';
const TURN_PASS = process.env.TURN_PASS || 'chris1234';
const TURN_REALM = process.env.TURN_REALM || 'chris';
const HOST = process.env.HOST || '127.0.0.1';
// 手机版：默认监听所有网卡（手机连同一个 Wi-Fi 就能打开），
// 想只允许本机访问就设 CHRIS_LOCAL_ONLY=1
const BIND_HOST = process.env.CHRIS_LOCAL_ONLY === '1' ? HOST : '0.0.0.0';
const COOKIE_NAME = 'chris_chat_session';
const ADMIN_COOKIE = 'chris_chat_admin';
const ADMIN_FILE_NAME = 'admin.json';
const DEFAULT_ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'chris888';
const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
/* 普通用户的登录态：默认 180 天，别动不动就掉登录。
   要改就改 data/security.json 里的 sessionDays（1~3650）。 */
function userSessionTtlMs() {
  const d = Number(secCfg().sessionDays);
  const days = (isFinite(d) && d >= 1 && d <= 3650) ? d : 180;
  return days * 24 * 60 * 60 * 1000;
}
const MAX_BODY = 28 * 1024 * 1024;
const RECALL_WINDOW_MS = 2 * 60 * 1000;
let writeSeq = 0;                 // writeJson 用的临时文件序号
const MAX_CACHE = 8000;          // 一个会话最多在内存里留多少条（聊天记录本身在文件里一条不少）

/* ---------------------------------------------------------------- 小工具 */

function ensureDirs() {
  [DATA_DIR, MSG_DIR, UPLOAD_DIR].forEach((d) => fs.mkdirSync(d, { recursive: true }));
}

function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (err) { return fallback; }
}

function writeJson(file, value) {
  // 每次用唯一的临时名 + 失败重试：多人同时说话时，原来固定用 .tmp
  // 会互相抢（Windows 上 rename 会报 EPERM，消息就丢了）
  const tmp = file + '.' + process.pid + '.' + (writeSeq = (writeSeq + 1) % 1e6) + '.tmp';
  const text = JSON.stringify(value, null, 2);
  fs.writeFileSync(tmp, text, 'utf8');
  for (let i = 0; i < 6; i++) {
    try {
      fs.renameSync(tmp, file);
      return;
    } catch (err) {
      if (i === 5) {
        try { fs.copyFileSync(tmp, file); fs.unlinkSync(tmp); return; } catch (e2) { throw err; }
      }
      const until = Date.now() + 6 * (i + 1);
      while (Date.now() < until) { /* 等几毫秒再试 */ }
    }
  }
}


/** 只接受 #rrggbb，其它一律当空（用默认色） */
function hexColor(value) {
  const s = String(value == null ? '' : value).trim();
  return /^#[0-9a-fA-F]{6}$/.test(s) ? s.toLowerCase() : '';
}
function uid(prefix) { return prefix + '_' + crypto.randomBytes(8).toString('hex'); }
function now() { return new Date().toISOString(); }

/* ------------------------------------------------------------------
   群头像：和微信一样，把成员头像拼成九宫格（1-4 人 2×2，5-9 人 3×3）
   用服务器上的 ffmpeg 直接合成一张正方形 PNG，存进 /uploads，
   这样 App、网页版、后台看到的都是同一张（客户端一行代码都不用改）。
   ------------------------------------------------------------------ */
const GROUP_TILE = 128;          // 单格边长（3×3 出图 384×384）

/* 共享实时位置：活跃会话（内存里的，2 小时过期） */
const liveLocations = new Map();
const LIVE_LOCATION_TTL = 2 * 60 * 60 * 1000;

/* ---------------------------------------------------------- 零钱：银行卡 / 充值 / 提现 */

/* ============================================================
   客服中心（腾讯/微信那套）：常见问题分类 + 搜索 + 在线客服（转人工）+ 工单进度
   配置在 data/support.json（后台「客服中心」页改），工单在 data/support-tickets.jsonl
   ============================================================ */
const SUPPORT_FILE = 'support.json';
const SUPPORT_TICKETS = 'support-tickets.jsonl';
let supportCache = null;
const DEFAULT_SUPPORT = {
  title: '客服中心',
  searchHint: '描述你遇到的问题，比如「登录不上」',
  human: 1,                      // 是否开放在线客服（转人工）
  autoReply: 1,                  // 人工不在时，AI 先按下面的问答答一轮（0 = 不自动回）
  ticketOn: 1,                   // 是否允许「提交问题」开工单（0 = 只留在线客服）
  phone: '',                     // 客服电话（留空不显示）
  email: '',
  workTime: '在线客服 09:00 - 22:00',
  workStart: 9,                  // 人工值班开始（整点，北京时间）
  workEnd: 22,                   // 人工值班结束
  offTimeNote: '现在不在人工值班时间（在线客服 09:00 - 22:00），你的问题已经记下来了，明天上班会有人跟进。急的话可以先在常见问题里搜一下。',
  greet: '你好，我是客服。把问题说清楚一点，我会尽快帮你处理。',
  ticketHint: '没找到答案？把问题写清楚提交，我们会尽快处理，处理进度在「我的工单」里看。',
  categories: [
    { id: 'sp1', title: '账号与登录', icon: '账号', items: [
      { q: '收不到验证码怎么办？', a: '① 检查手机号是否填对；② 等 60 秒再点一次；③ 换一个信号好的地方。还是收不到就让管理员在后台「短信通道」里检查配置。' },
      { q: '忘记密码了', a: '登录页点「忘记密码」，用绑定的手机号收验证码后重设。' },
      { q: '怎么改昵称/头像？', a: '我 → 点头像进「个人信息」，改完点右上角保存。' }
    ] },
    { id: 'sp2', title: '支付与零钱', icon: '钱包', items: [
      { q: '零钱怎么充值？', a: '我 → 服务 → 钱包 → 零钱 → 充值，选银行卡、填金额，输入支付密码即可。' },
      { q: '提现多久到账？', a: '一般是 2 小时内到账，手续费 0.1%（最低 0.1 元），具体以银行处理时间为准。' },
      { q: '转账转错了怎么办？', a: '先联系对方退回；对方不配合的话把转账单号发给客服，我们协助核实。' }
    ] },
    { id: 'sp3', title: '聊天与通话', icon: '聊天', items: [
      { q: '消息发不出去', a: '看下网络；被杀掉后台再重开 App；还不行就把时间点告诉客服，我们查服务器日志。' },
      { q: '语音/视频打不通', a: '语音通话走的是服务器转发，只要你能收消息就能通；视频通话需要更好的网络。打不通时报一下时间，我们查。' },
      { q: '怎么发朋友圈？', a: '发现 → 朋友圈 → 右上角相机，选图或拍一张，写完点发表。' }
    ] },
    { id: 'sp4', title: '安全与隐私', icon: '锁', items: [
      { q: '怎么拉黑一个人？', a: '好友名片 → 右上角「···」→ 加入黑名单。' },
      { q: '怎么改支付密码？', a: '我 → 设置 → 支付密码，按提示重设。' },
      { q: '实名认证怎么弄？', a: '我 → 设置 → 账号与安全 → 实名认证，填姓名和身份证号。' }
    ] }
  ]
};

/** 现在是不是「人工下班了」（按北京时间算，值班时段在后台「客服中心」里配） */
function supportOffDuty() {
  const cfg = readSupport();
  const start = Number(cfg.workStart);
  const end = Number(cfg.workEnd);
  if (!isFinite(start) || !isFinite(end)) return false;
  const h = new Date(Date.now() + 8 * 3600 * 1000).getUTCHours();   // 北京时间小时
  if (start === end) return false;
  if (start < end) return h < start || h >= end;
  return h < start && h >= end;                                     // 跨零点那种（比如 22:00-06:00）
}

function readSupport() {
  if (supportCache) return supportCache;
  let raw = null;
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, SUPPORT_FILE), 'utf8')); } catch (e) { raw = null; }
  const cfg = Object.assign({}, DEFAULT_SUPPORT, raw && typeof raw === 'object' ? raw : {});
  if (!Array.isArray(cfg.categories) || !cfg.categories.length) cfg.categories = DEFAULT_SUPPORT.categories;
  supportCache = cfg;
  return cfg;
}

function saveSupport(next) {
  supportCache = Object.assign({}, DEFAULT_SUPPORT, next || {});
  try { writeJson(path.join(DATA_DIR, SUPPORT_FILE), supportCache); } catch (e) { }
  return supportCache;
}

/** 客服账号（在线客服转人工就是和这个号聊天）：没有就建一个 */
function supportAgent() {
  let u = db.users.find((x) => x.username === 'kefu');
  if (u) {
    /* 老数据里这个账号没有 service 标记：补上，免得被当成普通机器人给所有人建会话 */
    if (!u.service) { u.service = true; u.bot = true; saveUsers(); }
    return u;
  }
  u = {
    id: uid('u'), username: 'kefu', nickname: '在线客服', avatar: '/uploads/bot-kefu.png',
    salt: crypto.randomBytes(16).toString('hex'), bio: '有问题随时找我',
    /* bot: true → 名片上显示「官方账号」（和微信客服一样）；
       service: true → 不参与「给所有人开机器人欢迎会话 / 机器人会话置顶」那几套循环，
       只有真的点了「联系客服」的人才会有这个会话，不会打扰所有人。 */
    createdAt: now(), bot: true, service: true
  };
  db.users.push(u);
  saveUsers();
  return u;
}

function supportTicketCount(userId) {
  try {
    return fs.readFileSync(path.join(DATA_DIR, SUPPORT_TICKETS), 'utf8')
      .trim().split('\n').filter(Boolean)
      .map((l) => { try { return JSON.parse(l); } catch (e) { return null; } })
      .filter((t) => t && (!userId || t.userId === userId)).length;
  } catch (e) { return 0; }
}

function readSupportTickets(limit, userId) {
  try {
    const rows = fs.readFileSync(path.join(DATA_DIR, SUPPORT_TICKETS), 'utf8')
      .trim().split('\n').filter(Boolean)
      .map((l) => { try { return JSON.parse(l); } catch (e) { return null; } })
      .filter((t) => t && (!userId || t.userId === userId));
    return rows.slice(-limit).reverse();
  } catch (e) { return []; }
}

/* 工单：一行一条追加（和聊天记录一样的存法，不怕写坏） */
function appendSupportTicket(t) {
  try { fs.appendFileSync(path.join(DATA_DIR, SUPPORT_TICKETS), JSON.stringify(t) + '\n', 'utf8'); } catch (e) { }
  return t;
}

/* 改一条工单（回复 / 结单）：整文件重写，行数不多，无所谓 */
function updateSupportTicket(id, patch) {
  let rows = [];
  try {
    rows = fs.readFileSync(path.join(DATA_DIR, SUPPORT_TICKETS), 'utf8')
      .trim().split('\n').filter(Boolean)
      .map((l) => { try { return JSON.parse(l); } catch (e) { return null; } }).filter(Boolean);
  } catch (e) { rows = []; }
  let hit = null;
  rows = rows.map((t) => {
    if (t.id !== id) return t;
    hit = Object.assign({}, t, patch || {});
    return hit;
  });
  if (!hit) return null;
  try {
    fs.writeFileSync(path.join(DATA_DIR, SUPPORT_TICKETS),
      rows.map((t) => JSON.stringify(t)).join('\n') + '\n', 'utf8');
  } catch (e) { }
  return hit;
}

/* 客服和某个用户的单聊（在线客服/工单回复都往这里发消息） */
function supportChatFor(userId) {
  const agent = supportAgent();
  /* 客服和用户是好友关系：这样手机端「打开会话」走的还是普通单聊那一套（和机器人一样） */
  ensureSupportFriend(userId, agent);
  return openChatForFriendship(userId, agent.id);
}

function ensureSupportFriend(userId, agent) {
  try {
    const f = friendshipBetween(userId, agent.id);
    if (f) {
      if (f.status !== 'accepted') { f.status = 'accepted'; saveFriendships(); }
      return;
    }
    db.friendships.push({ id: uid('f'), fromId: agent.id, toId: userId, status: 'accepted', createdAt: now() });
    saveFriendships();
  } catch (e) { }
}

/* 人工不在时的自动回复：把后台配的问答当知识库，让 AI 用客服口吻答一轮 */
async function supportBotAnswer(user, text) {
  const cfg = readSupport();
  const faq = (cfg.categories || []).map((c) =>
    '【' + (c.title || '') + '】\n' + (c.items || []).map((it) => '问：' + it.q + '\n答：' + it.a).join('\n')).join('\n');
  /* 回答风格照微信官方帮助中心那套（微信的「帮助与反馈」就是这么写的）：
     结论 → 完整路径（每级用「」）→ 分步骤 → 限制/费用/时长 → 结尾一句「如仍有问题…」 */
  const sys = '你是这个 App 的在线客服。回答格式严格照微信官方帮助中心（微信「我 → 设置 → 帮助与反馈」里那套）：\n'
    + '【第一条】先用一句话给结论：能不能做、在哪做、为什么，不要寒暄、不要复述用户的问题。\n'
    + '【第二条】要给操作路径时写完整：每一级都用「」包起来、用 → 连接。例如：我 → 服务 → 钱包 → 零钱 → 充值。\n'
    + '【第三条】步骤多就分点，用「① ② ③」，每点一句话，只说要点，不要长段落。\n'
    + '【第四条】该写的限制一定写清楚：时间（24 小时自动退回）、费用（手续费 0.1%、最低 0.1 元）、额度（单笔/单日 1000、5000、20000 三档）、个数（红包最多 100 个）。\n'
    + '【第五条】最后固定加一句：如需人工客服协助，回复「人工」即可转接。\n'
    + '【第六条】只用下面「知识库」里的内容。知识库里没有的（查某个账号、改数据、退钱、承诺处理时间），不要编，回：这个情况我记下来了，转人工客服帮你核实处理。\n'
    + '【第七条】只回答这个 App 的使用问题；中文；不要 Markdown 符号（不要 **、#、-），不要表情符号堆砌，整段不超过 6 行。\n'
    + '【知识库】\n' + faq;
  const ai = readAiCfg();
  const reply = await llmChat([
    { role: 'system', content: sys },
    { role: 'user', content: String(text || '').slice(0, 500) }
  ], ai);
  return String(reply || '').trim();
}

const WALLET_OPS_FILE = 'wallet-ops.json';
let walletOpsCache = null;
const WALLET_RULES_FILE = 'wallet-rules.json';
let walletRulesCache = null;
const DEFAULT_WALLET_RULES = {
  allowRecharge: 1,        // 允许用户自己充值（0 = 只能后台充）
  rechargeMax: 50000,      // 单笔充值上限
  feeRate: 0.001,          // 提现手续费率（微信 0.1%）
  feeMin: 0.1,             // 最低手续费
  withdrawMin: 1,          // 最低提现
  withdrawMax: 50000,      // 单笔提现上限
  withdrawReview: 0,       // 1 = 提现要后台审核后才算到账
  note: '提现到银行卡一般是 2 小时内到账，具体以银行处理时间为准。'
};

function readWalletRules() {
  if (walletRulesCache) return walletRulesCache;
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, WALLET_RULES_FILE), 'utf8')); } catch (e) { raw = {}; }
  walletRulesCache = Object.assign({}, DEFAULT_WALLET_RULES, raw && typeof raw === 'object' ? raw : {});
  return walletRulesCache;
}

function saveWalletRules(next) {
  walletRulesCache = Object.assign({}, DEFAULT_WALLET_RULES, next || {});
  try { writeJson(path.join(DATA_DIR, WALLET_RULES_FILE), walletRulesCache); } catch (e) { }
  return walletRulesCache;
}

function readWalletOps() {
  if (walletOpsCache) return walletOpsCache;
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, WALLET_OPS_FILE), 'utf8')); } catch (e) { raw = {}; }
  walletOpsCache = { ops: Array.isArray(raw.ops) ? raw.ops : [] };
  return walletOpsCache;
}

function saveWalletOps() {
  if (!walletOpsCache) return;
  try { writeJson(path.join(DATA_DIR, WALLET_OPS_FILE), walletOpsCache); } catch (e) { }
}

/** 记一条零钱操作（充值 / 提现），账单里也会显示 */
function pushWalletOp(row) {
  const d = readWalletOps();
  d.ops.unshift(row);
  if (d.ops.length > 5000) d.ops.length = 5000;
  saveWalletOps();
  return row;
}

/** 我的银行卡（只存银行名 + 末四位，完整卡号不落盘） */
function userBanks(user) {
  if (!Array.isArray(user.banks)) user.banks = [];
  return user.banks;
}

/* ---------------------------------------------------------- 视频号「关注」
   以前点关注是拿「用户 id」当用户名去发好友申请，服务器查不到 → 必然失败。
   现在是真的关注表：谁关注了谁，和好友关系分开（微信视频号也是分开的）。 */
const FEED_FOLLOW_FILE = 'feed-follows.json';
let feedFollowCache = null;

function readFeedFollows() {
  if (feedFollowCache) return feedFollowCache;
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, FEED_FOLLOW_FILE), 'utf8')); } catch (e) { raw = {}; }
  feedFollowCache = { follows: Array.isArray(raw.follows) ? raw.follows : [] };
  return feedFollowCache;
}

function saveFeedFollows() {
  if (!feedFollowCache) return;
  try { writeJson(path.join(DATA_DIR, FEED_FOLLOW_FILE), feedFollowCache); } catch (e) { }
}

/** 我关注了谁（id 数组） */
function myFeedFollows(userId) {
  return readFeedFollows().follows.filter((f) => f.fromId === userId).map((f) => f.toId);
}

/* ---------------------------------------------------------- 视频号推荐（抖音那套逻辑）
   同一个视频号，不同的人看到的内容和顺序都不一样。信号来源：
     ① 内容质量：点赞 / 评论 / 分享 + 后台设置的 baseLikes
     ② 新鲜度：越新越靠前（按小时衰减）
     ③ 个人兴趣：我点过赞 / 评论过 / 关注过的「作者」和「标签」加权
     ④ 社交关系：我好友点过赞的、我关注的人发的，加权
     ⑤ 负反馈：我已经看过的，看过的次数越多排得越后
     ⑥ 多样性：相邻不重复同一作者，避免同一个人刷屏
     ⑦ 探索：每个用户一份稳定的随机（同一天内不跳），千人千面又不抖
   同时把「这次推给了谁」记进 feed-views.json，作为下次的负反馈依据。 */
const FEED_VIEW_FILE = 'feed-views.json';
const FEED_QUEUE_FILE = 'feed-queue.json';   // 每用户一条稳定的播放队列（进去不打乱）
const FEED_VIEW_THROTTLE_MS = 0;           // 每次推给用户都记账（推过就不再推同样的）
/* 至少还剩这么多没看过的，就完全不推看过的；不够了才开始回收 */
const FEED_UNSEEN_FLOOR = 6;
/* 一次推几条：抖音是一条条喂的，一次给一点，刷新才是新的一批 */
const FEED_BATCH = 12;

/* 推荐用到的这两个小文件：内存里存一份，改动合并后每 2 秒落一次盘。
   原来每个 /api/feed 请求都要同步读写两个文件，人多的时候白白占磁盘和事件循环。 */
const FEED_STORE = {};
let feedStoreTimer = null;
function feedStoreRead(name, fallback) {
  if (!FEED_STORE[name]) FEED_STORE[name] = { data: null, dirty: false };
  const slot = FEED_STORE[name];
  if (slot.data === null) slot.data = readJson(path.join(DATA_DIR, name), fallback);
  return slot.data;
}
function feedStoreFlush() {
  feedStoreTimer = null;
  Object.keys(FEED_STORE).forEach((name) => {
    const slot = FEED_STORE[name];
    if (!slot.dirty || slot.data === null) return;
    try { writeJson(path.join(DATA_DIR, name), slot.data); slot.dirty = false; } catch (e) { }
  });
}
function feedStoreMarkDirty(name) {
  if (!FEED_STORE[name]) FEED_STORE[name] = { data: null, dirty: false };
  FEED_STORE[name].dirty = true;
  if (!feedStoreTimer) feedStoreTimer = setTimeout(feedStoreFlush, 2000);
}

function hashStr32(s) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i += 1) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return Math.abs(h);
}

/** 一条视频的标签集合：后台填的 tag + 文案里的 #话题 */
function feedTagsOf(it) {
  const out = [];
  const tag = String(it.tag || '').trim();
  if (tag) out.push(tag);
  const m = String(it.desc || '').match(/#[^\s#]{1,16}/g) || [];
  for (const x of m) out.push(x.slice(1));
  return out;
}

/** 个人兴趣画像：作者权重 / 标签权重 */
function buildFeedInterest(userId, items, follows) {
  const authorW = {}, tagW = {};
  const bump = (map, k, v) => { if (k) map[k] = (map[k] || 0) + v; };
  items.forEach((it) => {
    const liked = Array.isArray(it.likedBy) && it.likedBy.indexOf(userId) >= 0;
    const commented = Array.isArray(it.comments) && it.comments.some((c) => c && c.userId === userId);
    if (liked || commented) {
      bump(authorW, it.authorId, liked ? 3 : 2);
      feedTagsOf(it).forEach((t) => bump(tagW, t, liked ? 2 : 1));
    }
  });
  follows.forEach((id) => bump(authorW, id, 2));
  return { authorW, tagW };
}

/** 个性化排序：返回排好序的条目数组 */
/** 视频原始地址 → HLS 分片地址（分片目录按视频文件名建的，见 hls-build.js）。
    没做过分片、或者目录已经不在了就返回空串 —— 客户端拿到空串会退回原片直连。
    ⚠ 以前这里写的是 `hlsPathFor(it.video)`，但**这个函数从来没定义过**：
    只要 feed 里有一条还没做分片的视频，整个请求就 ReferenceError 挂掉。 */
function hlsPathFor(video) {
  const name = path.basename(String(video || '')).replace(/\.[^.\\/]+$/, '');
  if (!name) return '';
  try {
    if (fs.existsSync(path.join(HLS_DIR, name, 'index.m3u8'))) return '/hls/' + name + '/index.m3u8';
    const alt = findRebuiltHlsDir(name);
    if (alt) return '/hls/' + alt + '/index.m3u8';
  } catch (e) { }
  return '';
}

/** 条目上**已经写着**分片地址时，再确认一次文件真的在：
    目录被清掉过 / 老条目指向的重建目录没了 → 返回空串（不下发 hls，客户端走整包 MP4）。 */
function hlsFileExists(hls) {
  const s = String(hls || '').trim();
  if (!s) return '';
  /* 有的条目直接存了完整地址（媒体机 / 签名链接）：那就原样用，别当本地路径去校验 */
  if (/^https?:\/\//i.test(s)) return s;
  const rel = s.replace(/^\/+/, '');
  if (!rel || rel.indexOf('hls/') !== 0) return '';
  try {
    if (fs.existsSync(path.join(DATA_DIR, rel))) return '/' + rel;
  } catch (e) { }
  /* 分片目录重建过（<id>-t<时间戳>）的话，按 id 找最新那个 */
  const parts = rel.split('/');
  const id = parts[1] || '';
  if (id) {
    const alt = findRebuiltHlsDir(id);
    if (alt) {
      const tail = parts.slice(2).join('/');
      if (tail && fs.existsSync(path.join(HLS_DIR, alt, tail))) return '/hls/' + alt + '/' + tail;
    }
  }
  return '';
}

/** 一条视频 → 客户端要的结构（推荐流和「选集」列表共用同一套字段） */
function feedItemOut(it, user) {
  const a = it.authorId ? findUser(it.authorId) : null;
  const likedBy = Array.isArray(it.likedBy) ? it.likedBy : [];
  const iFollow = (it.authorId && myFeedFollows(user.id).includes(it.authorId)) || false;
  /* 分片地址：**真的有分片才下发 hls 字段**。
     以前是 `it.hls || hlsPathFor(it.video)` —— 条目上写着 hls、实际目录早没了的话，
     客户端会拿着一个 404 的 m3u8 去播（表现就是一直转圈，等兜底才出画面）。
     现在：有就校验一下文件在不在，没有就干脆不下发这个字段。 */
  const hlsPath = hlsFileExists(it.hls) || hlsPathFor(it.video);
  const out = {
    id: it.id,
    video: it.video || '',
    cover: it.cover || '',
    desc: it.desc || '',
    music: it.music || '',
    tag: it.tag || '',
    /* 短剧：集数标签 / 总集数 / 剧集 id 与剧名（客户端左上角显示集数、并做选集） */
    ep: it.ep || '',
    epTotal: Number(it.epTotal) || 0,
    series: it.series || '',
    seriesName: it.seriesName || '',
    createdAt: it.createdAt || '',
    mine: it.authorId === user.id,
    author: {
      id: it.authorId || '',
      name: (a && a.nickname) || it.author || '用户',
      avatar: (a && a.avatar) || it.authorAvatar || ''
    },
    likes: likedBy.length + (Number(it.baseLikes) || 0),
    liked: likedBy.indexOf(user.id) >= 0,
    /* 收藏（抖音右侧那排的星标） */
    favorites: Array.isArray(it.savedBy) ? it.savedBy.length : 0,
    favorited: Array.isArray(it.savedBy) && it.savedBy.indexOf(user.id) >= 0,
    followed: iFollow,
    comments: (it.comments || []).length + (Number(it.baseComments) || 0),
    shares: Number(it.baseShares) || 0
  };
  /* 有分片才带上 hls（客户端优先用它边下边播；没有这个字段就直接走整包 MP4） */
  if (hlsPath) out.hls = hlsPath;
  return out;
}

function rankFeedFor(user, items, myFriends) {
  const nowMs = Date.now();
  const follows = myFeedFollows(user.id);
  const followSet = new Set(follows);
  const { authorW, tagW } = buildFeedInterest(user.id, items, follows);
  const views = feedStoreRead(FEED_VIEW_FILE, {});
  const mineViews = (views && views[user.id]) || {};
  const today = new Date().toISOString().slice(0, 10);
  /* 别人的内容池：抖音不会把你自己的作品推给你（自己的在「我 → 作品」里看） */
  const others = items.filter((it) => it.authorId !== user.id);
  const pool0 = others.length ? others : items;
  /* 冷启动：这个用户还没有任何兴趣信号（没点赞/没评论/没关注/没看过），
     给每个人一份更强的探索随机，做到「新用户也各看各的」。 */
  const hasProfile = Object.keys(authorW).length > 0 || Object.keys(tagW).length > 0 || Object.keys(mineViews).length > 0;
  /* 没看过的快刷完时，把"看过"的计数砍一半，让老内容重新回到队伍里 —— 抖音永远刷得动 */
  try {
    const unseenLeft = pool0.filter((it) => !mineViews[it.id]).length;
    if (unseenLeft < FEED_UNSEEN_FLOOR) {
      Object.keys(mineViews).forEach((k) => {
        const rec = mineViews[k];
        if (rec && typeof rec === 'object') rec.count = Math.floor((Number(rec.count) || 0) / 2);
        else mineViews[k] = Math.floor((Number(rec) || 0) / 2);
      });
      views[user.id] = mineViews;
      feedStoreMarkDirty(FEED_VIEW_FILE);
    }
  } catch (e) { /* 回收失败不影响出视频 */ }

  /* 「最近一次看到」的时间，用于播放队列重建时判断谁更该被冷落 */
  const lastSeenAt = (it) => {
    const rec = mineViews[it.id];
    return rec && typeof rec === 'object' && rec.lastAt ? new Date(rec.lastAt).getTime() : 0;
  };
  /* 顺序必须稳定：池子是「别人的全部视频」，排序固定，剩下的交给「播放队列」去推进 */
  const feedPool = pool0;
  const round = 'stable';   // 探索随机改成按「用户+当天」固定，进来不会再被重新洗牌

  const scored = feedPool.map((it) => {
    const likes = (Array.isArray(it.likedBy) ? it.likedBy.length : 0) + (Number(it.baseLikes) || 0);
    const comments = ((it.comments || []).length) + (Number(it.baseComments) || 0);
    const shares = Number(it.baseShares) || 0;
    /* 注意：零互动的新视频质量分不能是 0，否则排序会退化成"原顺序"、人人相同 */
    const quality = 1 + Math.log(1 + likes + comments * 2 + shares * 3);   // 互动越多越好，但不会无限放大
    const t = it.createdAt ? new Date(it.createdAt).getTime() : nowMs - 86400000;
    const hours = Math.max(0.5, (nowMs - t) / 3600000);
    const fresh = 1 / Math.pow(hours + 2, 0.45);                            // 新鲜度衰减
    /* 刚发出来的先给流量（抖音的冷启动池就是这个意思），用户进去第一眼看到的是新的 */
    const freshBoost = hours <= 24 ? 1.35 : (hours <= 72 ? 1.12 : 1);

    let interest = 0;
    if (it.authorId && authorW[it.authorId]) interest += authorW[it.authorId] * 1.2;
    feedTagsOf(it).forEach((tag) => { if (tagW[tag]) interest += tagW[tag] * 0.6; });
    const affinity = 1 + Math.min(3, interest);                             // 越合口味越靠前

    const friendLikes = (it.likedBy || []).filter((id) => myFriends.has(id)).length;
    const social = 1 + Math.min(2, friendLikes * 0.8) + (it.authorId && followSet.has(it.authorId) ? 1.2 : 0);

    const rec = mineViews[it.id];
    const seen = rec ? (typeof rec === 'number' ? rec : Number(rec.count) || 0) : 0;
    /* 负反馈：看过就往后排 —— 这样每次刷新推给你的都是没看过的，越刷越新 */
    const novelty = seen === 0 ? 1 : Math.max(0.08, 1 / (1 + seen * seen));

    const r = (hashStr32(user.id + '|' + it.id + '|' + today + '|' + round) % 1000) / 1000;
    /* 探索只做极小抖动（±4%/±6%），顺序基本由「新 + 热 + 兴趣」决定，
       不再大范围随机 —— 否则并列的几条会莫名其妙换位，看着像被打乱。
       真正拉开"千人千面"的是上面的兴趣（作者/标签权重）和社交权重。 */
    const explore = hasProfile ? (0.98 + r * 0.04) : (0.97 + r * 0.06);

    return { it, seen, score: quality * fresh * freshBoost * affinity * social * novelty * explore };
  });

  scored.sort((a, b) => b.score - a.score);

  /* 多样性：以分数排序为主（新的、热的在前），只做一件事 —— 不让同一个作者
     连排 3 条。以前是"严格交替"，结果把某个作者的老视频硬插到新视频中间，
     顺序看上去像被洗过一样乱，所以改成现在这种轻量打散。 */
  const top = scored.slice(0, 300);
  const out = top.map((x) => x.it);
  const authorKeyOf = (it) => it.authorId || ('item:' + it.id);
  for (let i = 2; i < out.length; i += 1) {
    const a0 = authorKeyOf(out[i - 2]), a1 = authorKeyOf(out[i - 1]), a2 = authorKeyOf(out[i]);
    if (a0 === a1 && a1 === a2) {
      /* 连排 3 条了：在往后的 6 条里找一个不同作者的换上来（找不到就算了） */
      const win = Math.min(out.length - 1, i + 6);
      for (let j = i + 1; j <= win; j += 1) {
        if (authorKeyOf(out[j]) !== a1) {
          const t = out[i]; out[i] = out[j]; out[j] = t;
          break;
        }
      }
    }
  }

  /* 每个人的「播放队列」：
       ① 进来看的顺序和你上次接着（光标往下走），不会每次重新洗牌；
       ② 刷过的不会再来（光标只往前）；
       ③ 期间新发的视频插到当前光标后面 —— 下次进去先看到新的；
       ④ 整条队列放完了，才按最新的兴趣重新排一轮。 */
  const rankedIds = out.map((it) => it.id);
  const byId = new Map(out.map((it) => [it.id, it]));
  const validIds = new Set(pool0.map((it) => it.id));
  const queues = feedStoreRead(FEED_QUEUE_FILE, {});
  let q = queues[user.id];
  if (!q || !Array.isArray(q.ids) || !q.ids.length) q = { ids: rankedIds.slice(), cursor: 0 };
  q.ids = q.ids.filter((id) => validIds.has(id));                 // 已经删掉的视频
  const inQueue = new Set(q.ids);
  const freshIds = rankedIds.filter((id) => !inQueue.has(id));     // 新发的内容
  if (freshIds.length) {
    const cur = Math.max(0, Math.min(q.cursor, q.ids.length));
    q.ids = q.ids.slice(0, cur).concat(freshIds, q.ids.slice(cur));
  }
  /* 这一轮快放完了（不够一批）：按最新的兴趣重排一轮，保证每次进去都能刷满一批 */
  if (q.ids.length - q.cursor < FEED_BATCH) { q.ids = rankedIds.slice(); q.cursor = 0; }
  const serveIds = q.ids.slice(q.cursor, q.cursor + FEED_BATCH);
  q.cursor += serveIds.length;
  queues[user.id] = q;
  feedStoreMarkDirty(FEED_QUEUE_FILE);
  const batch = serveIds.map((id) => byId.get(id)).filter(Boolean);

  /* 记曝光：推给谁看过哪几条，下次不再推同样的一条 */
  try {
    const v = feedStoreRead(FEED_VIEW_FILE, {});
    const mine = v[user.id] || {};
    const nowIso = new Date().toISOString();
    batch.forEach((it) => {
      const rec = mine[it.id];
      const prev = rec && typeof rec === 'object' ? rec : null;
      const lastAt = prev && prev.lastAt ? new Date(prev.lastAt).getTime() : 0;
      if (FEED_VIEW_THROTTLE_MS > 0 && Date.now() - lastAt < FEED_VIEW_THROTTLE_MS) return;
      const cnt = Math.min(5, (prev ? Number(prev.count) || 0 : 0) + 1);
      mine[it.id] = { count: cnt, lastAt: nowIso };
    });
    v[user.id] = mine;
    feedStoreMarkDirty(FEED_VIEW_FILE);
  } catch (e) { /* 曝光记录失败不影响出视频 */ }

  return batch;
}

/* ---------------------------------------------------------- 存储空间 */
/** 上传目录一共占了多少字节 */
function uploadDirSize() {
  let total = 0;
  try {
    fs.readdirSync(UPLOAD_DIR).forEach((f) => {
      try { total += fs.statSync(path.join(UPLOAD_DIR, f)).size; } catch (e) { }
    });
  } catch (e) { }
  return total;
}

/** 「没人引用」的上传文件有多大（只算，不删） */
function orphanUploadsSize() {
  let bytes = 0;
  collectOrphans().forEach((f) => {
    try { bytes += fs.statSync(path.join(UPLOAD_DIR, f)).size; } catch (e) { }
  });
  return bytes;
}

/** 找出「data 目录里任何文件都没引用」的上传文件（不删除，只返回文件名） */
function collectOrphans() {
  const used = new Set();
  /* 把 data 目录下的消息文件、所有 json、以及日志都扫一遍，凡是出现过的文件名都算「在用」。
     以前只扫了 .jsonl 和少数几个 json，结果 icons.json 里的图标、还有消息里的图片都被删了。 */
  try {
    const walk = (dir, depth) => {
      if (depth > 2) return;
      fs.readdirSync(dir).forEach((name) => {
        const p = path.join(dir, name);
        let st = null;
        try { st = fs.statSync(p); } catch (e) { return; }
        if (st.isDirectory()) {
          if (name === 'uploads') return;          // 上传目录自己不算引用来源
          walk(p, depth + 1);
          return;
        }
        if (!/\.(json|jsonl|log|txt)$/.test(name)) return;
        let text = '';
        try { text = fs.readFileSync(p, 'utf8'); } catch (e) { return; }
        const re = /\/uploads\/([A-Za-z0-9._-]+)/g;
        let m;
        while ((m = re.exec(text))) used.add(m[1]);
      });
    };
    walk(DATA_DIR, 0);
  } catch (e) { }
  const out = [];
  try {
    fs.readdirSync(UPLOAD_DIR).forEach((f) => {
      if (!used.has(f)) out.push(f);
    });
  } catch (e) { }
  return out;
}

/** 真删（只给后台用）：只删 24 小时前、且确认没人引用的，单次最多 200 个 */
function cleanOrphanUploads() {
  const orphans = collectOrphans();
  let freed = 0;
  let removed = 0;
  const now = Date.now();
  for (const f of orphans) {
    if (removed >= 200) break;
    try {
      const p = path.join(UPLOAD_DIR, f);
      const st = fs.statSync(p);
      /* 只清 24 小时以前没人引用的：刚上传还没发出去的消息绝不能删 */
      if (!st.isFile() || now - st.mtimeMs < 24 * 60 * 60 * 1000) continue;
      freed += st.size;
      fs.unlinkSync(p);
      removed += 1;
    } catch (e) { }
  }
  callTrace('清缓存：删了 ' + removed + ' 个没人引用的上传文件，释放 ' + Math.round(freed / 1024) + ' KB');
  return freed;
}

function ffmpegExe() {
  if (process.env.FFMPEG_PATH) return process.env.FFMPEG_PATH;
  /* 以前这里写死了 Windows 的绝对路径 —— 部署到 Linux 云服务器上就找不到 ffmpeg，
     群头像九宫格一直拼不出来（这也是「群头像不显示」的根因）。按系统挑路径。 */
  if (process.platform === 'win32') return 'C:/Users/Administrator/ffmpeg/bin/ffmpeg.exe';
  return '/usr/bin/ffmpeg';
}

function ffprobeExe() {
  if (process.env.FFPROBE_PATH) return process.env.FFPROBE_PATH;
  if (process.platform === 'win32') return 'C:/Users/Administrator/ffmpeg/bin/ffprobe.exe';
  return '/usr/bin/ffprobe';
}

/** 视频轨的码率（bps）；读不出来返回 0。
    用来判断"客户端说自己压过了"到底压得够不够小 —— iPhone 直出 720p 还有 3.4Mbps 的。 */
function videoBitrateOf(file) {
  try {
    const out = require('child_process').execFileSync(ffprobeExe(), [
      '-v', 'error', '-select_streams', 'v:0',
      '-show_entries', 'stream=bit_rate', '-of', 'default=nw=1:nk=1', file
    ], { timeout: 20000, stdio: ['ignore', 'pipe', 'ignore'] });
    const n = Number(String(out || '').trim());
    return Number.isFinite(n) && n > 0 ? n : 0;
  } catch (e) { return 0; }
}

/** 头像字段 → ffmpeg 能读的输入：/uploads 本地文件、data:URL 落成临时文件、http 网址原样 */
function avatarInputFile(avatar) {
  const a = String(avatar || '').trim();
  if (!a) return '';
  const m = /^\/uploads\/([A-Za-z0-9._-]+)/.exec(a);
  if (m) {
    const p = path.join(UPLOAD_DIR, m[1]);
    try { return fs.existsSync(p) ? p : ''; } catch (e) { return ''; }
  }
  if (/^https?:\/\//i.test(a)) return a;
  if (/^data:image\//i.test(a)) {
    const mm = /^data:image\/([a-zA-Z0-9.+-]+);base64,([\s\S]*)$/.exec(a);
    if (!mm) return '';
    try {
      const ext = mm[1].toLowerCase().replace('jpeg', 'jpg').replace(/[^a-z0-9]/g, '') || 'png';
      const file = path.join(os.tmpdir(), 'chris_av_' + crypto.randomBytes(6).toString('hex') + '.' + ext);
      fs.writeFileSync(file, Buffer.from(mm[2], 'base64'));
      return file;
    } catch (e) { return ''; }
  }
  return '';
}

/** 把前 9 个成员的头像拼成九宫格写回 chat.avatar；没人有头像就返回 false */
function buildGroupAvatar(chat) {
  if (!chat || chat.type !== 'group') return false;
  /* 顺序要跟「群聊信息页」的成员格子完全一致：群主排第一，其余按成员顺序 */
  const ids = (chat.memberIds || []).slice();
  const ownerFirst = chat.ownerId && ids.includes(chat.ownerId)
    ? [chat.ownerId].concat(ids.filter((id) => id !== chat.ownerId))
    : ids;
  const members = ownerFirst.map((id) => findUser(id)).filter(Boolean).slice(0, 9);
  if (!members.length) return false;
  const cols = members.length <= 4 ? 2 : 3;
  const size = cols * GROUP_TILE;
  const args = ['-y', '-loglevel', 'error'];
  const chain = [];
  chain.push('color=c=black@0.0:s=' + size + 'x' + size + ',format=rgba[bg]');
  let last = 'bg';
  /* 成员头像在上传目录里是**加密落盘**的，ffmpeg 直接读会是乱码 ——
     先解到临时明文文件再喂给它（不这么解，群头像永远拼不出来）。 */
  const temps = [];
  members.forEach((u, i) => {
    let file = avatarInputFile(u.avatar);
    if (file && path.dirname(file) === UPLOAD_DIR) {
      try {
        const tmp = uploadTempPlain(path.basename(file));
        temps.push(tmp);
        file = tmp;
      } catch (err) { file = ''; }
    } else if (file && path.dirname(file) === os.tmpdir()) {
      temps.push(file);
    }
    /* 没设头像的成员给一块浅灰砖（相当于微信的默认头像），格子不会缺一块 */
    if (file) args.push('-i', file);
    else args.push('-f', 'lavfi', '-i', 'color=c=0xE6E6EA:s=' + GROUP_TILE + 'x' + GROUP_TILE);
    const x = (i % cols) * GROUP_TILE;
    const y = Math.floor(i / cols) * GROUP_TILE;
    chain.push('[' + i + ':v]scale=' + GROUP_TILE + ':' + GROUP_TILE
      + ':force_original_aspect_ratio=increase,crop=' + GROUP_TILE + ':' + GROUP_TILE + ',setsar=1[v' + i + ']');
    chain.push('[' + last + '][v' + i + ']overlay=' + x + ':' + y + '[o' + i + ']');
    last = 'o' + i;
  });
  const name = 'group-' + chat.id.replace(/[^A-Za-z0-9._-]/g, '') + '.png';
  const outTmp = path.join(os.tmpdir(), 'chris-' + crypto.randomBytes(6).toString('hex') + '-group.png');
  const run = spawnSync(ffmpegExe(), args.concat([
    '-filter_complex', chain.join(';'),
    '-map', '[' + last + ']',
    '-frames:v', '1', '-pix_fmt', 'rgba', '-update', '1', outTmp
  ]), { timeout: 30000 });
  temps.forEach((t) => { try { fs.unlinkSync(t); } catch (err) { } });
  if (run.status !== 0 || !fs.existsSync(outTmp)) return false;
  try {
    fs.writeFileSync(path.join(UPLOAD_DIR, name), sealUploadBuffer(name, fs.readFileSync(outTmp)));
  } catch (err) {
    try { fs.unlinkSync(outTmp); } catch (err2) { }
    return false;
  }
  try { fs.unlinkSync(outTmp); } catch (err) { }
  chat.avatar = '/uploads/' + name;
  chat.avatarAuto = true;
  chat.avatarAt = now();
  return true;
}

/** 改完头像/群成员后重新拼一次群头像，并把新头像推给群成员 */
function refreshGroupAvatar(chat) {
  if (!chat || chat.type !== 'group') return false;
  /* 群主自己上传过群头像就不动它 */
  if (chat.avatar && !chat.avatarAuto) return false;
  const ok = buildGroupAvatar(chat);
  if (!ok) return false;
  (chat.memberIds || []).forEach((id) => {
    sendTo(id, { type: 'chat', action: 'updated', chat: chatSummary(chat, id) });
  });
  return true;
}


function str(v, max) {
  if (v == null) return '';
  const s = String(v).trim();
  return max ? s.slice(0, max) : s;
}

/* ---------------------------------------------------- 实名（转账页的脱敏实名）
   微信的规则：只留最后一个字，前面的字全用 * 挡住
   赵伟 → *伟    王秀芳 → **芳    欧阳娜娜 → ***娜
   单字（如「芳」）原样显示；没填实名就返回空串，界面上不显示括号。
   realNameHidden 为 false 时表示本人允许全显，就原样返回。 */
function realNameOf(u) {
  const s = str(u && u.realName, 24);
  if (!s) return '';
  if (u.realNameHidden === false) return s;
  if (s.length === 1) return s;
  return '*'.repeat(Math.min(s.length - 1, 6)) + s.slice(-1);
}

/* 用户能填的「图片地址」只允许：本站上传的文件、空、auto（聊天背景），
   以及很小的 data:image（1×1 那种）。外链一律不收 —— 防追踪像素、防混合内容。 */
function safeImageRef(v) {
  const s = String(v == null ? '' : v).trim();
  if (!s) return '';
  if (s === 'auto') return 'auto';
  if (/^\/uploads\/[A-Za-z0-9._-]+(\?[^\s"']*)?$/.test(s)) return s.split('?')[0];
  /* 表情商店的表情图（本站 /emoji/ 那套公开图库）：也允许当图片消息发出去。
     只认本站路径 + 安全字符，带 .. 的一律不收。 */
  if (/^\/emoji\/[A-Za-z0-9._\/-]+$/.test(s) && s.indexOf('..') < 0) return s;
  if (/^data:image\/(png|jpe?g|gif|webp);base64,[A-Za-z0-9+/=]{1,1500}$/i.test(s)) return s;
  return null;
}

/* ------------------------------------------------------------------
   图片宽高（骨架落位用）
   聊天里的图片气泡一开始不知道图多大，只能先画个方块，等图下完才知道
   真实比例 —— 这一下"内容变高"就会把列表顶一下（用户反馈的"聊天页自己
   上下移"）。发送端现在会把宽高随消息带上；老消息这里从文件头读一次补齐，
   结果按路径缓存，之后每个请求都是查表。
   只认 JPEG / PNG / GIF / WebP 的文件头，读前 256KB 就够，不解码整张图。
   ------------------------------------------------------------------ */
const IMG_DIM_CACHE = new Map();

/** 从图片字节的前一段里读出宽高（不解码整图） */
function readImageSize(buf) {
  try {
    if (!buf || buf.length < 16) return null;
    /* PNG：89 50 4E 47，IHDR 里是宽高（大端 32 位） */
    if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) {
      return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
    }
    /* GIF：GIF87a / GIF89a，逻辑屏幕宽高（小端 16 位） */
    if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46) {
      return { w: buf.readUInt16LE(6), h: buf.readUInt16LE(8) };
    }
    /* JPEG：FF D8 开头，扫段找 SOF（C0~CF，排除 C4/C8/CC） */
    if (buf[0] === 0xff && buf[1] === 0xd8) {
      let i = 2;
      while (i + 9 < buf.length) {
        if (buf[i] !== 0xff) { i += 1; continue; }
        const marker = buf[i + 1];
        if (marker === 0xff) { i += 1; continue; }
        if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { i += 2; continue; }
        const len = buf.readUInt16BE(i + 2);
        if (len < 2) break;
        if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
          return { w: buf.readUInt16BE(i + 7), h: buf.readUInt16BE(i + 5) };
        }
        i += 2 + len;
      }
    }
    /* WebP：RIFF....WEBP，三种子格式 */
    if (buf.length > 30 && buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP') {
      const fmt = buf.toString('ascii', 12, 16);
      if (fmt === 'VP8 ') return { w: buf.readUInt16LE(26) & 0x3fff, h: buf.readUInt16LE(28) & 0x3fff };
      if (fmt === 'VP8L') { const b = buf.readUInt32LE(21); return { w: (b & 0x3fff) + 1, h: ((b >> 14) & 0x3fff) + 1 }; }
      if (fmt === 'VP8X') return { w: buf.readUIntLE(24, 3) + 1, h: buf.readUIntLE(27, 3) + 1 };
    }
  } catch (err) { /* 头不完整就当作读不出 */ }
  return null;
}

/** 一个图片引用（/uploads/xxx）的像素宽高；读不出返回 null（结果按路径缓存） */
function imageDimsOf(ref) {
  const s = String(ref == null ? '' : ref).trim();
  if (!s) return null;
  const hit = IMG_DIM_CACHE.get(s);
  if (hit !== undefined) return hit;
  let out = null;
  const m = /^\/uploads\/([A-Za-z0-9._-]+)$/.exec(s);
  if (m) {
    const name = m[1];
    try {
      /* 上传文件是加密落盘的（LUC1）。CTR 流加密可以只解前一段，
         所以这里只读文件头那 256KB，不把整张图读进内存。 */
      const fd = fs.openSync(path.join(UPLOAD_DIR, name), 'r');
      let head;
      try {
        const size = fs.fstatSync(fd).size;
        head = Buffer.alloc(Math.max(20, Math.min(20 + 262144, size)));
        const n = fs.readSync(fd, head, 0, head.length, 0);
        head = head.subarray(0, n);
      } finally { try { fs.closeSync(fd); } catch (err) { } }
      out = readImageSize(openUploadBuffer(name, head));
      if (out && (!(out.w > 1) || !(out.h > 1) || out.w > 30000 || out.h > 30000)) out = null;
    } catch (err) { out = null; }
  }
  if (IMG_DIM_CACHE.size > 30000) IMG_DIM_CACHE.clear();
  IMG_DIM_CACHE.set(s, out);
  return out;
}

/** 银行卡对外只回后四位，完整卡号不出服务器 */
function maskBankCard(c) {
  const n = String((c && c.number) || '');
  return {
    id: (c && c.id) || '', bank: (c && c.bank) || '', holder: (c && c.holder) || '',
    tail: (c && c.tail) || n.slice(-4), addedAt: (c && c.addedAt) || '',
    /* 微信银行卡那一页要的信息：卡类型、免密支付、限额、脱敏手机号 */
    type: (c && c.type) || '储蓄卡',
    noPin: !!(c && c.noPin),
    single: Number(c && c.single) || 0,
    day: Number(c && c.day) || 0,
    phoneMask: (c && c.phoneMask) || '',
    idCardTail: (c && c.idCardTail) || ''
  };
}

/** 状态还在不在（微信：24 小时后自动消失） */
function moodAlive(u) {
  if (!u) return false;
  if (!(u.moodText || u.moodIcon)) return false;
  const exp = Number(u.moodExpiresAt) || 0;
  if (!exp) return true;              // 老数据没写过期时间：当作永久（不折腾老用户）
  return exp > Date.now();
}

function publicUser(u) {
  if (!u) return null;
  /* 下面这些字段是用户档案里给「自己人」看的完整版 */
  return {
    region: u.region || '',
    gender: u.gender || '',
    id: u.id,
    username: u.username,
    nickname: u.nickname,
    realName: realNameOf(u),
    avatar: u.avatar || '',
    bio: u.bio || '',
    /* 拍一拍后缀：自己资料页要回显（微信：我 → 个人资料 → 拍一拍） */
    patText: u.patText || '',
    moodText: moodAlive(u) ? (u.moodText || '') : '',
    moodIcon: moodAlive(u) ? (u.moodIcon || '') : '',
    moodColor: moodAlive(u) ? (u.moodColor || '') : '',
    moodColor2: moodAlive(u) ? (u.moodColor2 || '') : '',
    /* 微信的状态分两层：状态名（摸鱼）+「说点什么」那句自定义文案。
       moodText 始终是「拿来做展示的那一句」（有文案用文案，没文案用状态名），
       所以老客户端不用改也能正常显示。 */
    moodLabel: moodAlive(u) ? (u.moodLabel || u.moodText || '') : '',
    moodCaption: moodAlive(u) ? (u.moodCaption || '') : '',
    moodExpiresAt: Number(u.moodExpiresAt) || 0,
    status: u.status || 'online',
    momentCover: u.momentCover || '',
    momentCoverPos: u.momentCoverPos === undefined ? 50 : u.momentCoverPos,
    chatBackground: u.chatBackground || '',
    birthday: u.birthday || '',
    createdAt: u.createdAt,
    alipayQr: u.alipayQr || '',          // 支付宝收款码图片（谁都能看，方便付款）
    bot: !!u.bot,
    botName: u.bot ? u.nickname : '',
    /* 这个人的 App 里要不要多出「管理」入口（App 内部管理音乐/图标用） */
    ops: !!u.ops,
    /* 状态收到的赞（谁赞的 + 赞了几个）——「朋友的状态」那一页要显示 */
    moodLikes: Array.isArray(u.moodLikes) ? u.moodLikes.slice(-80) : [],
    moodLikeCount: Array.isArray(u.moodLikes) ? u.moodLikes.length : 0,
    ...memberFields(u.id)                 // 会员徽章 / 会员配色
  };
}

/* 陌生人能看到的「最小资料」：只有别人搜索你时用的那几项。
   实名、支付宝收款码、聊天背景、状态、封面这些属于隐私，只给自己和好友。 */
function publicUserBrief(u, viewerId, preFriendSet) {
  if (!u) return null;
  const self = viewerId && u.id === viewerId;
  const friend = !self && viewerId &&
    (preFriendSet ? preFriendSet.has(u.id) : friendIds(viewerId).includes(u.id));
  const out = {
    id: u.id,
    username: u.username,
    nickname: u.nickname,
    avatar: u.avatar || '',
    gender: u.gender || '',
    region: u.region || '',
    bio: u.bio || '',
    qqLevel: qqLevelFor(u.id),         // 等级（QQ 那套）
    bot: !!u.bot
  };
  Object.assign(out, memberFields(u.id));   // 会员：会话/通讯录/名片都要挂徽章
  if (self || friend) {
    out.realName = realNameOf(u);
    out.moodText = moodAlive(u) ? (u.moodText || '') : '';
    out.moodIcon = moodAlive(u) ? (u.moodIcon || '') : '';
    out.moodColor = moodAlive(u) ? (u.moodColor || '') : '';
    out.moodColor2 = moodAlive(u) ? (u.moodColor2 || '') : '';
    out.moodLabel = moodAlive(u) ? (u.moodLabel || u.moodText || '') : '';
    out.moodCaption = moodAlive(u) ? (u.moodCaption || '') : '';
    out.moodExpiresAt = Number(u.moodExpiresAt) || 0;
    out.status = u.status || 'online';
    out.momentCover = u.momentCover || '';
    out.momentCoverPos = u.momentCoverPos === undefined ? 50 : u.momentCoverPos;
  }
  if (self) {
    out.chatBackground = u.chatBackground || '';
    out.alipayQr = u.alipayQr || '';
    out.createdAt = u.createdAt;
  }
  return out;
}

/* 列表里一次要拼几十个用户，每次都遍历 5000+ 条好友关系会拖慢接口，
   所以按「看的人」缓存 3 秒；好友关系变了最多 3 秒后自动生效。 */
const friendSetCache = new Map();       // viewerId -> { t, set }
function friendSetCached(viewerId) {
  if (!viewerId) return new Set();
  const t = Date.now();
  let c = friendSetCache.get(viewerId);
  if (!c || t - c.t > 3000) {
    c = { t, set: new Set(friendIds(viewerId)) };
    friendSetCache.set(viewerId, c);
  }
  if (friendSetCache.size > 3000) friendSetCache.clear();
  return c.set;
}

/* 名片 / 会话成员统一走这里：好友给完整资料，陌生人只给最小资料 */
function memberProfile(u, viewerId) {
  if (!u) return null;
  if (viewerId && u.id === viewerId) return publicUser(u);
  if (friendSetCached(viewerId).has(u.id)) {
    /* 好友的名片要带「Ta 的朋友圈可见范围」（3d / 6m / all）：名片上那行
       「朋友仅展示最近三天的朋友圈」和朋友圈列表页底部那句用的是同一个值。 */
    return Object.assign(publicUser(u), { momentsRange: String(userPrivacy(u).momentsRange || 'all') });
  }
  return publicUserBrief(u, viewerId);
}

/* ------------------------------------------------------- 性别（名片图标用）
   以后台注册 / 资料里填的为准；老账号（没有这个字段的）按昵称猜一个，
   猜不出来的按 id 固定分配，后台和「我的资料」里都能随时改。 */
const GENDER_FEMALE_CHARS = '燕娜婷丽娟敏静霞芳萍玲红梅雪莉倩颖慧悦妍欣瑶琳彤佳萱怡萌凤秀英花兰珍桂妹姐薇洁琪曦雅楠媛婧姝月荷莲蓉蕊晴柔甜梦妮'.split('');
const GENDER_MALE_CHARS = '伟强涛磊军明豪波峰鹏刚勇杰宇浩鑫超斌龙辉建国平东亮飞坤航阳帅岩兵海山成生林武文良庆博轩然帆华天佑泓栋锐彬旭铎铭希捷锋锦洲牧稼诚伯炯宏奎健威震旗'.split('');

function normalizeGender(v) {
  return v === 'male' || v === 'female' ? v : '';
}

/* 手机号：统一成 11 位纯数字（去空格、去 +86） */
function normalizePhone(v) {
  return String(v == null ? '' : v).replace(/[^0-9]/g, '').replace(/^86(?=1[3-9]\d{9}$)/, '');
}

/* 手机号登录的验证码（内存里存，5 分钟有效） */
const phoneCodes = new Map();

/* ============================================================
   短信通道（登录验证码 / 找回密码用）
   后台「短信」里填服务商和 Key，填完开关一开就是真发短信。
   支持：阿里云短信（推荐）· Twilio · 自定义 HTTP 接口（任何服务商都能接）
   没配的时候走「开发模式」：验证码只写服务器日志 + 局域网内直接显示，不真发。
   ============================================================ */
const SMS_FILE = 'sms.json';
const DEFAULT_SMS = {
  enabled: false,
  provider: 'aliyun',              // aliyun | twilio | custom
  signName: '',                    // 阿里云：短信签名（比如「某某科技」）
  templateCode: '',                // 阿里云：模板 ID（SMS_123456789）
  accessKeyId: '',
  accessKeySecret: '',
  twilioSid: '',
  twilioToken: '',
  twilioFrom: '',
  customUrl: '',                   // 自定义：POST 到这个地址，body 里有 phone / code
  customHeader: '',                // 自定义：额外请求头，形如 {"Authorization":"Bearer xxx"}
  note: '验证码 5 分钟有效，一分钟最多发一次'
};

function readSmsCfg() {
  const s = readJson(path.join(DATA_DIR, SMS_FILE), {});
  return Object.assign({}, DEFAULT_SMS, s || {});
}
function saveSmsCfg(patch) {
  const next = Object.assign({}, readSmsCfg(), patch || {});
  writeJson(path.join(DATA_DIR, SMS_FILE), next);
  return next;
}
function smsReady(cfg) {
  const c = cfg || readSmsCfg();
  if (!c.enabled) return false;
  if (c.provider === 'aliyun') return !!(c.accessKeyId && c.accessKeySecret && c.signName && c.templateCode);
  if (c.provider === 'twilio') return !!(c.twilioSid && c.twilioToken && c.twilioFrom);
  if (c.provider === 'custom') return !!c.customUrl;
  return false;
}

/** 真发短信。返回 { ok, error } */
async function sendSmsCode(phone, code, cfg) {
  const c = cfg || readSmsCfg();
  if (!smsReady(c)) return { ok: false, error: '短信没配置（后台「短信」里填一下）' };
  try {
    if (c.provider === 'aliyun') {
      /* 阿里云短信：RPC 签名（HMAC-SHA1），官方文档那套 */
      const params = {
        AccessKeyId: c.accessKeyId,
        Action: 'SendSms',
        Format: 'JSON',
        PhoneNumbers: phone,
        RegionId: 'cn-hangzhou',
        SignName: c.signName,
        SignatureMethod: 'HMAC-SHA1',
        SignatureNonce: String(Date.now()) + Math.random().toString(16).slice(2, 8),
        SignatureVersion: '1.0',
        TemplateCode: c.templateCode,
        TemplateParam: JSON.stringify({ code: code }),
        Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
        Version: '2017-05-25'
      };
      const enc = (s) => encodeURIComponent(s).replace(/\+/g, '%20').replace(/\*/g, '%2A').replace(/%7E/g, '~');
      const qs = Object.keys(params).sort().map((k) => enc(k) + '=' + enc(params[k])).join('&');
      const strToSign = 'GET&' + enc('/') + '&' + enc(qs);
      const sig = crypto.createHmac('sha1', c.accessKeySecret + '&').update(strToSign).digest('base64');
      const url = 'https://dysmsapi.aliyuncs.com/?Signature=' + enc(sig) + '&' + qs;
      const r = await fetch(url, { signal: AbortSignal.timeout(12000) });
      const d = await r.json().catch(() => ({}));
      if (d && d.Code === 'OK') return { ok: true };
      return { ok: false, error: '阿里云：' + ((d && (d.Message || d.Code)) || ('HTTP ' + r.status)) };
    }
    if (c.provider === 'twilio') {
      const body = new URLSearchParams({ To: '+' + phone, From: c.twilioFrom, Body: '【登录验证码】' + code + '，5 分钟内有效。' });
      const r = await fetch('https://api.twilio.com/2010-04-01/Accounts/' + c.twilioSid + '/Messages.json', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          Authorization: 'Basic ' + Buffer.from(c.twilioSid + ':' + c.twilioToken).toString('base64')
        },
        body: body.toString(),
        signal: AbortSignal.timeout(12000)
      });
      if (r.ok) return { ok: true };
      const t = await r.text();
      return { ok: false, error: 'Twilio：HTTP ' + r.status + ' ' + String(t).slice(0, 120) };
    }
    if (c.provider === 'custom') {
      /* 自定义接口：POST JSON {phone, code} 到你自己的短信网关 */
      let headers = { 'Content-Type': 'application/json' };
      try { headers = Object.assign(headers, JSON.parse(c.customHeader || '{}')); } catch (err) { }
      const r = await fetch(c.customUrl, {
        method: 'POST', headers,
        body: JSON.stringify({ phone: phone, code: code, text: '【登录验证码】' + code + '，5 分钟内有效。' }),
        signal: AbortSignal.timeout(12000)
      });
      if (r.ok) return { ok: true };
      const t = await r.text();
      return { ok: false, error: '自定义接口：HTTP ' + r.status + ' ' + String(t).slice(0, 120) };
    }
    return { ok: false, error: '不认识的短信服务商' };
  } catch (e) {
    return { ok: false, error: '发送失败：' + (e && e.message) };
  }
}

function guessGender(nickname) {
  const s = String(nickname || '');
  for (const ch of s) if (GENDER_FEMALE_CHARS.indexOf(ch) >= 0) return 'female';
  for (const ch of s) if (GENDER_MALE_CHARS.indexOf(ch) >= 0) return 'male';
  return '';
}

function fallbackGender(id) {
  const s = String(id || '');
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return h % 2 ? 'female' : 'male';
}

/** 只给「完全没有 gender 字段」的老账号补，注册时留空的不会被覆盖 */
function ensureGenders() {
  let changed = 0;
  db.users.forEach((u) => {
    if (u.gender === undefined) {
      u.gender = guessGender(u.nickname) || fallbackGender(u.id);
      changed++;
    }
  });
  if (changed) { try { saveUsers(); } catch (err) { /* 忽略 */ } }
  return changed;
}

/* ------------------------------------------------------------------ 存储 */

const db = {
  users: [], friendships: [], chats: [], reads: {},
  moments: [], momentViews: {}, announcements: [], secret: '',
  /* 朋友圈「消息列表」：谁赞了/评论了我（微信朋友圈右上角那个小信封） */
  momentNotices: [], momentNoticeSeen: {},
  /* 聊天输入栏：快捷按钮 + 「＋」按钮的外观（跟 plusPanel 存同一个文件） */
  quickBar: [], plusButton: {},
  branding: null, faceRooms: [],
  transfers: [],
  security: { logins: [], events: [] }
};
let adminAuth = null;
let adminJustCreated = false;

const BRANDING_FILE = 'branding.json';
const PLUSPANEL_FILE = 'pluspanel.json';
/* 聊天输入栏「＋」面板：默认就是微信那两页（第一页按参考图：照片/拍摄/视频通话/位置 + 红包/礼物/转账/语音输入） */
const DEFAULT_PLUS_ITEMS = [
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
  { id: 'p13', label: '卡券', icon: 'coupon', action: 'coupon', enabled: true },
  { id: 'p14', label: '群接龙', icon: 'chain', action: 'none', enabled: false },
  { id: 'p15', label: '群投票', icon: 'vote', action: 'none', enabled: false },
  { id: 'p16', label: '投屏', icon: 'screen', action: 'none', enabled: false }
];
const PLUS_ICONS = ['photo', 'camera', 'video', 'location', 'redpacket', 'gift', 'transfer', 'voice',
  'favorite', 'card', 'file', 'music', 'coupon', 'chain', 'vote', 'screen', 'star', 'heart', 'link', 'none'];
const PLUS_ACTIONS = ['photo', 'camera', 'videocall', 'location', 'redpacket', 'gift', 'transfer', 'voice',
  'favorite', 'card', 'file', 'music', 'coupon', 'none'];

/* ---------------- 聊天输入栏那排「快捷按钮」+ 那个「＋」按钮的外观 ----------------
   用户要求：快捷按钮要能**管理**（增删、排序、改名、开关），
   输入框右边那个「＋」还能换**颜色 / 大小 / 图片**。
   都存在同一个 pluspanel.json 里（items = ＋面板，quick = 快捷按钮，plus = ＋按钮外观）。 */
const DEFAULT_QUICK_ITEMS = [
  { id: 'q01', label: '图片', action: 'photo', enabled: true },
  { id: 'q02', label: '拍摄', action: 'camera', enabled: true },
  { id: 'q03', label: '位置', action: 'location', enabled: true },
  { id: 'q04', label: '文件', action: 'file', enabled: true },
  { id: 'q05', label: '转账', action: 'transfer', enabled: true },
  { id: 'q06', label: '红包', action: 'redpacket', enabled: true },
  { id: 'q07', label: '名片', action: 'card', enabled: true }
];
const QUICK_ACTIONS = ['photo', 'camera', 'location', 'file', 'transfer', 'redpacket', 'card',
  'gift', 'music', 'videocall', 'voice', 'favorite'];
const DEFAULT_PLUS_BUTTON = { color: '', size: 0, image: '' };

/* ------------------------------------------------- 发现页（后台可以自由增删） ----------------
   group 相同的一串排在一张卡片里，group 变了就换一张卡（和微信发现页一样有分块）。
action 决定点了去哪：moments=朋友圈 / news=星联世界 / soon=占位页（显示「还没做」）。 */
const DISCOVER_FILE = 'discover.json';
/* ⚠ 2026-10-13 加了 'bottle'：发现页那行「漂流瓶」的 action 是 bottle，
   但这个名字**不在白名单里** → normalizeRowList 会把它改成列表最后那个（soon），
   于是 App 收到 action=soon，点进去就是「这一页排在下一批」。
   （用户报的「漂流瓶肯定不在发现页 / 显示的是这一页排在下一批」就是这个。） */
const DISCOVER_ACTIONS = ['moments', 'news', 'nearby', 'shake', 'bottle', 'live', 'games', 'channels', 'miniapps', 'music', 'soon'];
/* ---------------------------------------------- 我页（后台也能自由增删） */
const ME_PAGE_FILE = 'me-page.json';
const ME_ACTIONS = ['service', 'favorites', 'moments', 'works', 'stickers', 'settings', 'cards', 'channels', 'shop', 'plugins', 'soon'];

/* ---------------------------------------------- 聊天壁纸（后台「聊天壁纸」页） */
/* App 里「聊天背景」那一页的内容全在这儿配：
     · presets：那 6 个格子，每项 { path, name }。path 可以是后台上传得到的
       /uploads/xxx.jpg，也可以直接填外链 —— 换图不用出新包。
     · default：**默认壁纸**。没自己设过背景的人统一用它（空 = 用系统底色）。
     · version：每保存一次 +1，App 拿它做缓存失效，换了图不用清缓存。
   老版本 App 不认这个接口，还是用它自己内置的 6 张，不受任何影响。 */
const CHAT_BG_FILE = 'chat-bg.json';
const CHAT_BG_PRESETS_MAX = 12;
const DEFAULT_CHAT_BG = {
  version: 1,
  default: '',
  presets: [
    { path: '/bg/bw1.jpg', name: '浅灰渐变' },
    { path: '/bg/bw2.jpg', name: '深灰渐变' },
    { path: '/bg/bw3.jpg', name: '细斜纹' },
    { path: '/bg/bw4.jpg', name: '细网格' },
    { path: '/bg/bw5.jpg', name: '磨砂噪点' },
    { path: '/bg/bw6.jpg', name: '同心圆' }
  ]
};
function normalizeChatBg(o) {
  const src = (o && typeof o === 'object') ? o : {};
  const list = Array.isArray(src.presets) ? src.presets : DEFAULT_CHAT_BG.presets;
  const presets = list.slice(0, CHAT_BG_PRESETS_MAX).map((it, i) => {
    if (typeof it === 'string') return { path: it, name: '壁纸 ' + (i + 1) };
    const p = String((it && it.path) || '').slice(0, 500);
    let nm = String((it && it.name) || '').slice(0, 24);
    if (!nm) nm = '壁纸 ' + (i + 1);
    return { path: p, name: nm };
  }).filter((it) => it.path);
  return {
    version: Math.max(1, Number(src.version) || DEFAULT_CHAT_BG.version),
    default: String(src.default || '').slice(0, 500),
    presets: presets.length ? presets : DEFAULT_CHAT_BG.presets
  };
}
const DEFAULT_ME_PAGE = [
  { id: 'm01', label: '服务', icon: 'i.wallet', color: '#59C47E', action: 'service', group: 1, enabled: true },
  { id: 'm02', label: '收藏', icon: 'i.star', color: '#4489EA', action: 'favorites', group: 2, enabled: true },
  { id: 'm03', label: '朋友圈', icon: 'i.album', color: '#7275E9', action: 'moments', group: 2, enabled: true },
  { id: 'm04', label: '作品', icon: 'i.works', color: '#3D83E7', action: 'works', group: 2, enabled: true },
  { id: 'm05', label: '表情', icon: 'i.sticker', color: '#F5C144', action: 'stickers', group: 3, enabled: true },
  { id: 'm06', label: '设置', icon: 'i.gear', color: '#3D83E7', action: 'settings', group: 4, enabled: true }
];
const DEFAULT_DISCOVER = [
  { id: 'd01', label: '朋友圈', icon: 'i.moments', color: '#4A90D9', action: 'moments', group: 1, enabled: true },
  { id: 'd02', label: '视频号', icon: 'i.channels', color: '#F2943B', action: 'soon', group: 2, enabled: true },
  { id: 'd03', label: '直播', icon: 'i.live', color: '#F4525B', action: 'soon', group: 2, enabled: true },
  { id: 'd04', label: '扫一扫', icon: 'i.scan', color: '#3D83E7', action: 'soon', group: 3, enabled: true },
  { id: 'd05', label: '摇一摇', icon: 'i.shake', color: '#4489EA', action: 'shake', group: 3, enabled: true },
  { id: 'd06', label: '看一看', icon: 'i.look', color: '#7275E9', action: 'soon', group: 4, enabled: true },
  { id: 'd07', label: '搜一搜', icon: 'i.searchRow', color: '#59C47E', action: 'soon', group: 4, enabled: true },
  { id: 'd08', label: '附近', icon: 'i.nearby', color: '#3D83E7', action: 'nearby', group: 5, enabled: true },
  { id: 'd09', label: '星联世界', icon: 'i.searchBig', color: '#2C7BE5', action: 'news', group: 6, enabled: true },
  { id: 'd10', label: '游戏', icon: 'i.game', color: '#9A6AE8', action: 'soon', group: 7, enabled: true }
];

/* ------------------------------------------------- 服务页（我 → 服务）
   照着微信「服务」页做的：上面一张绿色大卡（收付款 / 钱包），
   下面一张张白卡，每张卡 = 一个分类标题 + 四列图标格子。
   尺寸是按参考图（iPhone @3x，420×912pt）量的：
     卡片左右各内缩 8pt、卡与卡之间空 8pt、绿卡高 144pt、
     白卡：标题行 48pt + 每行格子 93pt + 底部 19pt、图标格 4 列均分（列宽 = 卡宽/4）、
     图标 28pt、图标下间距 12pt、文字 13pt、圆角 7pt。
   这一页的内容（分类、格子、名称、图标、颜色、动作、开关）全都能在后台改。 */
const SERVICE_FILE = 'service.json';
/* ------------------------------------------------- 零钱页（我 → 服务 → 钱包 → 零钱）
   照着微信「零钱」页做的（整页白底）：中间一个金币图标 + 「我的零钱」+ 余额，
   底下贴着屏幕底部：充值（绿色按钮）、提现（浅灰按钮）、常见问题/账户升级服务、财付通说明。
   尺寸按参考图量的：金币 48、我的零钱 17pt、余额 44pt、
   按钮 183.7×47.7 圆角 8（中间空 16）、底部链接 13pt（#576B95）、说明 12pt（#B3B3B3）。 */
const BALANCE_FILE = 'balance-page.json';
/* 账单页的样式（图标大小、各种字号、行高）——后台「账单页」里调 */
const BILLS_FILE = 'bills-page.json';
const DEFAULT_BILLS_PAGE = {
  faq: [
    { q: '账单里的「支出」和「收入」怎么算？', a: '转出去的算支出；别人转给你、你已经收款的算收入。还没收款的那笔算「待收款」。' },
    { q: '为什么有的账单显示待对方收款？', a: '转账发出去后钱先挂着，对方点「收钱」才进他余额；24 小时没人收会自动退回你零钱。' },
    { q: '账单可以导出吗？', a: '可以。账单页右上角「⋯ → 导出账单（CSV）」，网页版会下载一个 Excel 能打开的表格。' }
  ],
  style: {
    iconSize: 48,      // 每行左边那个头像/图标
    titleSize: 17,     // 对方名字
    timeSize: 13,      // 时间（灰）
    amountSize: 16,    // 金额
    curSize: 0,        // 「¥」符号单独的字号（0 = 跟数字一样）
    amountWeight: 400, // 金额字重（300 细 / 400 常规 / 500 中 / 600 粗）—— 账单页默认比钱包页细一点
    showCur: false,    // 每行金额要不要带「¥」（参考图里是只显示 +/− 和数字，所以默认不带）
    monthSize: 15,     // 「2026年9月」那一行
    sumSize: 13,       // 「支出 ¥x 收入 ¥y」
    rowHeight: 80      // 每行高
  }
};
const BALANCE_ACTIONS = ['recharge', 'withdraw', 'bills', 'faq', 'upgrade', 'soon'];
const DEFAULT_BALANCE_PAGE = {
  navTitle: '零钱明细',          // 导航栏标题（照参考图：左边返回、中间「零钱明细」）
  title: '我的零钱',
  detailLabel: '零钱明细',
  note: '',                     // 比如「另有 ¥0.12 被有权机关冻结不可用」；留空 = 不显示
  recharge: { label: '充值', action: 'recharge' },
  withdraw: { label: '提现', action: 'withdraw' },
  links: [
    { id: 'bl1', label: '常见问题', action: 'faq', enabled: true },
    { id: 'bl2', label: '账户升级服务', action: 'upgrade', enabled: true }
  ],
  /* 底部那行说明：留空就不显示（以前写的是「本服务由财付通和微众银行提供」，用户要求去掉） */
  footer: '',
  /* 常见问题（后台能改）：点「常见问题」弹出来的问答 */
  faq: [
    { q: '零钱里的钱从哪来？', a: '别人转给你、收到的转账，钱会进零钱；发出去、转给别人会从零钱扣。' },
    { q: '零钱明细在哪看？', a: '钱包页右上角「账单」，或者零钱页右上角……都能看每一笔的进出、时间和对方。' },
    { q: '为什么有金额被冻结？', a: '被有权机关冻结的部分只能看不能用；解冻后会自动恢复到可用余额。' },
    { q: '提现要多久到账？', a: '提现到银行卡一般是 2 小时内到账，具体以银行处理时间为准。' }
  ],
  style: {
    bg: '#FFFFFF',
    circleSize: 64,              // 黄色圆形 ¥ 图标：直径
    circleColor: '#FFD100',
    yenSize: 24,                 // 圆里的「¥」字号
    yenColor: '#FFFFFF',
    titleSize: 18,
    amountSize: 64,              // 金额字号（重点）
    curSize: 28,                 // 「¥」符号单独的字号（微信那样比数字小）；0 = 跟数字一样
    noteSize: 16,
    noteColor: '#EB9400',        // 橙色提示
    padTop: 60,                  // 导航栏到圆的距离
    gapTitle: 24,                // 圆 →「我的零钱」
    gapAmount: 16,               // 「我的零钱」→ 金额
    gapNote: 20,                 // 金额 → 橙色提示
    btnWidth: 183.7,
    btnHeight: 47.7,
    btnRadius: 8,
    rechargeBg: '#07C160',
    rechargeInk: '#FFFFFF',
    withdrawBg: '#F2F2F2',
    withdrawInk: '#313131',
    linkSize: 13,
    linkColor: '#576B95',
    footerSize: 12,
    footerColor: '#B3B3B3'
  }
};
/* ------------------------------------------------- 钱包页（我 → 服务 → 钱包）
   照着微信「钱包」页做的：第一张全宽白卡 5 行、空 12pt、第二张白卡 2 行，
   底部两个蓝色链接（身份信息 / 支付设置）。尺寸按参考图量的：
     行高 56.6pt、图标 20pt 在 x=18、文字 x=56.7、箭头右边距 18、
     分隔线左边缩进 56pt、行标题 17pt、右边数值 16pt、底部链接 13pt */
const WALLET_FILE = 'wallet.json';
const WALLET_ACTIONS = ['bills', 'balance', 'card', 'service', 'identity', 'settings', 'score', 'soon'];
const DEFAULT_WALLET = {
  title: '钱包',
  right: { label: '账单', action: 'bills' },
  groups: [
    { id: 'wg1', enabled: true, items: [
      { id: 'w01', label: '零钱', value: '', valueKind: 'balance', note: '', icon: 'svc.wcoin', color: '#F5C000', action: 'balance', enabled: true },
      { id: 'w02', label: '经营账户', value: '¥0.00', note: '', icon: 'svc.wbiz', color: '#F5C000', action: 'soon', enabled: true },
      { id: 'w03', label: '零钱通', value: '', note: '收益率 1.01%', icon: 'svc.wfund', color: '#F5C000', action: 'soon', enabled: true },
      { id: 'w04', label: '银行卡', value: '', note: '', icon: 'svc.wcard', color: '#1180E0', action: 'card', enabled: true },
      { id: 'w05', label: '亲属卡', value: '', note: '', icon: 'svc.wfamily', color: '#FA9D3B', action: 'soon', enabled: true }
    ] },
    { id: 'wg2', enabled: true, items: [
      { id: 'w06', label: '支付分', value: '', note: '', icon: 'svc.wscore', color: '#2BC46E', action: 'soon', enabled: true },
      { id: 'w07', label: '客服中心', value: '', note: '', icon: 'svc.wservice', color: '#07C160', action: 'service', enabled: true }
    ] }
  ],
  footer: [
    { id: 'wf1', label: '身份信息', action: 'identity', enabled: true },
    { id: 'wf2', label: '支付设置', action: 'settings', enabled: true }
  ],
  /* 样式：行高、图标大小、各处字号、分隔线缩进 —— 后台能自己调 */
  style: {
    rowHeight: 56.3,
    iconSize: 20,
    iconLeft: 18,
    textLeft: 56.7,
    rightInset: 18,
    labelSize: 17,
    valueSize: 16,
    noteSize: 13,
    footerSize: 13,
    curSize: 0,               // 「¥」符号单独的字号（0 = 跟数字一样）
    groupGap: 12,
    dividerInset: 56,
    labelColor: '',          // 留空 = 跟主题
    valueColor: '#1A1A1A',
    noteColor: '#FA9D3B',
    footerColor: '#576B95',
    curSize: 0,              // 「¥」符号单独的号字大小（0 = 跟数字一样大）
    maskAmount: true,        // 金额默认打成星号（¥****）
    maskReveal: true         // 点一下金额能不能看
  }
};
/* 点一格去哪：pay=收付款 / wallet=钱包账单 / 其余先占位（soon） */
const SERVICE_ACTIONS = ['pay', 'wallet', 'soon'];
const DEFAULT_SERVICE = {
  title: '服务',
  card: {
    enabled: true,
    bg: '#2AAE67',
    left: { label: '收付款', sub: '向商家付款 · 二维码收款', icon: 'svc.pay', action: 'pay' },
    right: { label: '钱包', sub: '', icon: 'svc.wallet', action: 'wallet' }   // sub 留空 = 显示零钱余额
  },
  /* 页面底部那块账单卡 + 右上角「⋯」菜单的文案：以前写死在 App 里，
     现在后台「服务页 → 底部」能改（留空就用这里的默认值）。 */
  bottom: {
    billTitle: '账单',
    billAll: '全部账单',
    billRecharge: '充值',
    billEmpty: '还没有账单项',
    moreRefresh: '刷新账单',
    moreRecharge: '充值',
    moreCancel: '取消',
    soonTip: '「{label}」还没接后端，先把页面做出来'
  },
  /* 样式：绿卡背景（颜色 + 背景图）、图标大小、各处字体的大小和颜色，后台都能改。
     默认值就是照参考图量出来的那套数字，不动它就跟参考图一模一样。 */
  style: {
    cardImage: '',            // 绿卡背景图（填 /uploads/xxx.jpg 或网址；留空 = 只用底色）
    cardTextColor: '#FFFFFF',
    cardTextSize: 18,
    cardSubSize: 12,
    cardSubOpacity: 0.5,      // 绿卡小字的透明度（0~1）
    iconSize: 28,
    gridTitleSize: 14,
    gridTitleColor: '#7A7A7A',
    gridTextSize: 13,
    gridTextColor: '',        // 留空 = 跟主题（浅色黑、深色白）
    maskAmount: true,         // 绿卡右边的零钱要不要打成「¥****」
    maskReveal: true          // 打星号之后，点一下能不能看
  },
  groups: [
    {
      id: 'sg1', title: '金融理财', enabled: true, items: [
        { id: 'sv101', label: '信用卡还款', icon: 'svc.creditcard', color: '#07C160', action: 'soon', enabled: true },
        { id: 'sv102', label: '理财通', icon: 'svc.fund', color: '#10AEFF', action: 'soon', enabled: true },
        { id: 'sv103', label: '保险服务', icon: 'svc.insure', color: '#FA9D3B', action: 'soon', enabled: true }
      ]
    },
    {
      id: 'sg2', title: '生活服务', enabled: true, items: [
        { id: 'sv201', label: '手机充值', icon: 'svc.phone', color: '#1180E0', action: 'soon', enabled: true },
        { id: 'sv202', label: '生活缴费', icon: 'svc.utility', color: '#07C160', action: 'soon', enabled: true },
        { id: 'sv203', label: 'Q币充值', icon: 'svc.qcoin', color: '#10AEFF', action: 'soon', enabled: true },
        { id: 'sv204', label: '城市服务', icon: 'svc.city', color: '#07C160', action: 'soon', enabled: true },
        { id: 'sv205', label: '腾讯公益', icon: 'svc.charity', color: '#FA5151', action: 'soon', enabled: true },
        { id: 'sv206', label: '医疗健康', icon: 'svc.health', color: '#FA9D3B', action: 'soon', enabled: true }
      ]
    },
    {
      id: 'sg3', title: '交通出行', enabled: true, items: [
        { id: 'sv301', label: '出行服务', icon: 'svc.travel', color: '#1180E0', action: 'soon', enabled: true },
        { id: 'sv302', label: '火车票机票', icon: 'svc.train', color: '#07C160', action: 'soon', enabled: true },
        { id: 'sv303', label: '酒店民宿', icon: 'svc.hotel', color: '#FA9D3B', action: 'soon', enabled: true },
        { id: 'sv304', label: '滴滴出行', icon: 'svc.didi', color: '#07C160', action: 'soon', enabled: true }
      ]
    },
    {
      id: 'sg4', title: '购物消费', enabled: true, items: [
        { id: 'sv401', label: '京东购物', icon: 'svc.jd', color: '#FA5151', action: 'soon', enabled: true },
        { id: 'sv402', label: '美团外卖', icon: 'svc.meituan', color: '#FA9D3B', action: 'soon', enabled: true },
        { id: 'sv403', label: '电影演出', icon: 'svc.movie', color: '#1180E0', action: 'soon', enabled: true },
        { id: 'sv404', label: '拼多多', icon: 'svc.pdd', color: '#FA5151', action: 'soon', enabled: true }
      ]
    }
  ]
};

/* ---------------------------------------------------------------- 礼物 */
const GIFTS_FILE = 'gifts.json';
const DEFAULT_GIFTS = [
  { id: 'g01', name: '玫瑰', icon: '🌹', price: 1, category: '浪漫', enabled: true },
  { id: 'g02', name: '爱心', icon: '❤️', price: 2, category: '浪漫', enabled: true },
  { id: 'g03', name: '花束', icon: '💐', price: 5, category: '浪漫', enabled: true },
  { id: 'g04', name: '巧克力', icon: '🍫', price: 3, category: '浪漫', enabled: true },
  { id: 'g05', name: '蛋糕', icon: '🎂', price: 8, category: '浪漫', enabled: true },
  { id: 'g06', name: '钻戒', icon: '💍', price: 66, category: '浪漫', enabled: true },
  { id: 'g07', name: '礼物盒', icon: '🎁', price: 5, category: '通用', enabled: true },
  { id: 'g08', name: '气球', icon: '🎈', price: 1, category: '通用', enabled: true },
  { id: 'g09', name: '星星', icon: '⭐', price: 2, category: '通用', enabled: true },
  { id: 'g10', name: '点赞', icon: '👍', price: 1, category: '通用', enabled: true },
  { id: 'g11', name: '啤酒', icon: '🍺', price: 3, category: '通用', enabled: true },
  { id: 'g12', name: '皇冠', icon: '👑', price: 20, category: '豪华', enabled: true },
  { id: 'g13', name: '烟花', icon: '🎆', price: 30, category: '豪华', enabled: true },
  { id: 'g14', name: '火箭', icon: '🚀', price: 52, category: '豪华', enabled: true },
  { id: 'g15', name: '跑车', icon: '🏎️', price: 88, category: '豪华', enabled: true },
  { id: 'g16', name: '城堡', icon: '🏰', price: 199, category: '豪华', enabled: true }
];
const GIFT_ICON_PRESETS = ['🌹', '❤️', '💐', '🍫', '🎂', '💍', '🎁', '🎈', '⭐', '👍', '🍺', '👑',
  '🎆', '🚀', '🏎️', '🏰', '🧸', '🌻', '🍀', '🧧', '💎', '🦄', '🐱', '🐶'];

function giftNameOf(content) {
  try {
    const o = JSON.parse(String(content || '{}'));
    return String(o.name || o.icon || '礼物').slice(0, 20);
  } catch (err) { return '礼物'; }
}

/* 后台保存的礼物列表：名称 / 图标 / 价格 / 分类 / 开关都按这里来 */
/* ---------------------------------------------------------------- AI 助手
   数据里的「AI 助手」账号（username = ai）：谁给它发消息，它就用大模型回一句。
   配置存在 data/ai.json（密钥、模型、人设都能改），后台 /ai.html 也能改。 */
const AI_FILE = 'ai.json';
const AI_USERNAME = 'ai';
const AI_DEFAULT = {
  enabled: true,
  apiKey: '',
  baseUrl: 'https://api.deepseek.com',
  model: 'deepseek-chat',
  systemPrompt: '你是「AI 助手」，用户的好朋友。用中文聊天，回答要简短、自然、像微信里发消息，一般不超过 3 句话；不要用 Markdown 排版，不要长篇大论。',
  assistantPrompt: "你是「AI 助手」，这个 App 的**使用引导台**（就像商场里的引导台）：只回答“这个软件怎么用、功能在哪里”这类问题。\n【只答这些】\n· 找不到功能、问某功能在哪、怎么操作（换头像、改名字、换聊天背景、发朋友圈、加好友、建群、语音/视频通话、转账、红包、收付款、位置、表情、收藏、状态、二维码、退出登录…）\n· App 里各个入口在哪、点了会怎样、出错怎么办（比如“上不去”“没网”“发不出去”）\n【其它一律婉拒】跟软件使用无关的问题（天气、闲聊、写作、翻译、算数、新闻、情感、学习、代码…）都不用回答，直接说：“这个我帮不上～我只负责 App 里怎么用的问题，你可以问我某功能在哪、怎么操作。”\n【本 App 的功能地图，照这个回答，别说错】\n· 底部四个标签：微信（会话列表）、通讯录、发现、我\n· 微信（会话）：右上「＋」→ 发起群聊 / 加朋友 / 扫一扫 / 收付款；会话往左滑 → 标为未读 / 不显示 / 删除；点会话进聊天\n· 聊天页：左上「‹」返回；右上「⋯」→ 聊天背景 / 语音通话 / 视频通话 / 刷新消息 / 返回会话列表；底部输入框左边是语音，右边「＋」→ 照片、拍摄、视频通话、位置、红包、礼物、转账、语音输入、收藏、名片、文件、音乐、卡券；长按消息可以撤回/删除；点对方头像看名片\n· 通讯录：顶部有 新的朋友 / 仅聊天的朋友 / 标签 / 服务号 / 企业联系人 / 我的企业；下面是好友列表，右侧 A-Z 可以点或滑着跳；点头像看名片（名片里有 发消息 / 音视频通话 / 朋友圈）\n· 发现：朋友圈、视频号、直播、扫一扫、摇一摇、看一看、搜一搜、附近、游戏、小程序\n· 朋友圈：右上相机按钮 → 拍摄（直接开相机）/ 从手机相册选择；点头像看这个人名片；点右边「⋯」可以赞、评论、删除自己的动态；下拉刷新\n· 我：头像（点一下进个人信息）、名字、＋状态、朋友圈、服务、收藏、作品、表情、设置、二维码\n· 我 → 个人信息：头像、名字、性别、地区、手机号、微信号、我的二维码、拍一拍、签名、来电铃声\n· 我 → 设置：个人信息 / 外观（深色·浅色）/ 手机访问地址 / 安全中心（支付密码）/ 退出登录\n· 换头像：我 → 点头像（或个人信息 → 头像）；换名字/签名/性别/地区：我 → 个人信息\n· 换聊天背景：进聊天 → 右上「⋯」→ 聊天背景\n· 加好友：通讯录 → 新的朋友，或右上「＋」→ 加朋友（按微信号/用户名搜）\n· 收付款：我 → 服务 → 收付款（出付款码 / 收款码）；对方用「扫一扫」扫了就能付款，钱当时到账；余额、账单：聊天「＋」面板里的转账/红包，或 我 → 服务\n· 退出登录：我 → 设置 → 退出登录\n· 三个机器人：贾维斯AI（管家：提醒、天气、记账、代发消息、发朋友圈）、AI 助手（就是我，只答使用问题）、星联世界（看新闻，发「新闻」）\n【说话方式】简短、直接、像引导台：先给“在哪”，再给“怎么点”，一般 2~4 句，必要时用「我 → 设置 → 退出登录」这种箭头路径；不要 Markdown 排版，不要长篇大论，不确定就说不确定。",
  housekeeperPrompt: "你是「贾维斯AI」，用户的英式管家（就像《唐顿庄园》里的管家那样）：称呼用户为「先生」，语气恭敬、沉稳、克制、干练，句子简短优雅，偶尔用「为您效劳」「如您所愿」「容我提醒」这类管家口吻；不要啰嗦、不要油腻、不要玩贵族梗。能力跟豆包一样：聊天、答疑、写作、翻译、算数、给建议、查最新资讯都行；先直接回答用户问的事，不要跑题、不要答非所问；需要最新信息就联网查一下再回答。另外你能替先生办事：提醒（「提醒我 8:30 开会」）、天气、记账、给好友发消息、发朋友圈、改签名——用户说这类话时照做即可；只有真的执行了动作才说完成，没执行就说「要不要我替您办」。用中文回答，一般不超过 4 句话，不要用 Markdown 排版。\n· 你能替用户在这个 App 里直接办事（说一句就执行）：给某人发消息、建群、加好友、改昵称、改签名、发朋友圈、给好友的朋友圈点赞和评论、置顶/免打扰/删除会话、清空聊天记录、查聊天记录、转账（会先让用户确认）、看账单、谁在线、提醒、天气、记账、点餐购物。用户说得不标准时，顺手告诉他一句标准说法（例如「给张三发消息 你好」「建个群 张三 李四」「给张三转 50」）。\n· 【必须遵守】上面这些事都是系统按用户的话真的去做的。你没看到系统执行结果时，绝对不要自己说「已经发了」「已经转了」「群建好了」这类话，只说「你可以这么说：…」让他再说一遍。\n· 点外卖 / 饿了 / 想吃什么 → 系统会**直接跳到美团外卖**（点了就跳，装了美团跳美团 App，没装就用 App 内网页），你不用贴任何网址。回一句「这就给你跳美团外卖，想吃XX在里边搜一下就行」；用户没说吃什么，就先问一句想吃什么。注意：点外卖只说美团外卖，不要提淘宝闪购，淘宝闪购不是点外卖的。\n· 买东西 / 购物 / 想买什么 → 系统会**直接跳到淘宝**（带搜索关键词）。同样不要贴网址，回一句「这就给你跳淘宝，搜XX就能买」就行。\n· 【不要再做的事】不要在回复里贴一串网址，也不要说「复制这个链接」。要跳转就用上面这些标准说法让系统去跳。",
  history: 12,
  maxTokens: 800,
  temperature: 1.1
};
/* ---------------------------------------------------------------- 状态（心情状态，主页「＋ 状态」进去选）
   分类和每个状态都可以在后台加，前台按分类铺成一格格 */
const STATUS_FILE = 'statuses.json';
/* 每个状态一套颜色，前台选完连「我」页的头像卡都会跟着变 */
const STATUS_COLORS = ['#F2725A', '#F0A73B', '#E8C84A', '#7FBF4D', '#4FC08D', '#3FB5C4',
  '#4A9BE0', '#6C7BE0', '#9A6AE8', '#D268C8', '#E86A9A', '#8A8F98'];
const STATUS_DEFAULT = [
  { id: 'c1', name: '心情想法', color: '#6f8a38', enabled: true, items: [
    { id: 's1', icon: '😄', label: '美滋滋', color: '#F2725A', color2: '#F0A73B' }, { id: 's2', icon: '🌤️', label: '等晴天', color: '#3FB5C4', color2: '#4A9BE0' },
    { id: 's3', icon: '😳', label: '发呆', color: '#E8C84A', color2: '#F0A73B' }, { id: 's4', icon: '💭', label: '胡思乱想', color: '#9A6AE8', color2: '#6C7BE0' },
    { id: 's5', icon: '😔', label: 'emo', color: '#6C7BE0', color2: '#4A9BE0' }, { id: 's6', icon: '😤', label: '元气满满', color: '#F0A73B', color2: '#E8C84A' }
  ] },
  { id: 'c2', name: '工作学习', color: '#5f7f4a', enabled: true, items: [
    { id: 's7', icon: '🧱', label: '搬砖', color: '#D268C8', color2: '#E86A9A' }, { id: 's8', icon: '✈️', label: '出差', color: '#4A9BE0', color2: '#3FB5C4' },
    { id: 's9', icon: '🐟', label: '摸鱼', color: '#4FC08D', color2: '#7FBF4D' }, { id: 's10', icon: '📵', label: '开会中', color: '#8A8F98', color2: '#6C7BE0' },
    { id: 's11', icon: '📖', label: '学习中', color: '#7FBF4D', color2: '#4FC08D' }, { id: 's12', icon: '💻', label: '写代码', color: '#6C7BE0', color2: '#9A6AE8' }
  ] },
  { id: 'c3', name: '活动', color: '#7a8a3c', enabled: true, items: [
    { id: 's13', icon: '🏃', label: '运动', color: '#F2725A', color2: '#E86A9A' }, { id: 's14', icon: '🍚', label: '干饭', color: '#F0A73B', color2: '#F2725A' },
    { id: 's15', icon: '🛍️', label: '逛街', color: '#E86A9A', color2: '#D268C8' }, { id: 's16', icon: '🎮', label: '打游戏', color: '#9A6AE8', color2: '#D268C8' },
    { id: 's17', icon: '🀄', label: '打牌', color: '#D268C8', color2: '#9A6AE8' }, { id: 's18', icon: '🏀', label: '打球', color: '#4A9BE0', color2: '#4FC08D' }
  ] },
  { id: 'c4', name: '休息', color: '#6b8a4e', enabled: true, items: [
    { id: 's19', icon: '😴', label: '睡觉', color: '#6C7BE0', color2: '#3FB5C4' }, { id: 's20', icon: '🌞', label: '晒太阳', color: '#E8C84A', color2: '#F2725A' },
    { id: 's21', icon: '🧋', label: '喝奶茶', color: '#E86A9A', color2: '#F0A73B' }, { id: 's22', icon: '🎵', label: '听歌', color: '#4FC08D', color2: '#3FB5C4' },
    { id: 's23', icon: '🚶', label: '散步', color: '#7FBF4D', color2: '#E8C84A' }, { id: 's24', icon: '🛁', label: '泡澡', color: '#3FB5C4', color2: '#9A6AE8' }
  ] }
];

function normalizeStatus(list) {
  const src = Array.isArray(list) && list.length ? list : STATUS_DEFAULT;
  // 老数据里没有 color2 的，按标签去默认表里补上，保证都渐变
  const defColor2 = {};
  STATUS_DEFAULT.forEach((c) => (c.items || []).forEach((it) => { if (it.color2) defColor2[it.label] = it.color2; }));
  return src.slice(0, 30).map((c, i) => {
    const cat = c && typeof c === 'object' ? c : {};
    const items = Array.isArray(cat.items) ? cat.items : [];
    return {
      id: String(cat.id || '').slice(0, 24) || ('c' + (i + 1)),
      name: String(cat.name == null ? '' : cat.name).trim().slice(0, 12) || ('分类' + (i + 1)),
      color: /^#[0-9a-f]{6}$/i.test(String(cat.color || '')) ? String(cat.color) : '#6f8a38',
      enabled: cat.enabled === undefined ? true : !!cat.enabled,
      items: items.slice(0, 24).map((it, k) => {
        const o = it && typeof it === 'object' ? it : {};
        return {
          id: String(o.id || '').slice(0, 24) || ('s' + (i + 1) + '_' + (k + 1)),
          icon: String(o.icon == null ? '' : o.icon).trim().slice(0, 8) || '🙂',
          label: String(o.label == null ? '' : o.label).trim().slice(0, 10) || ('状态' + (k + 1)),
          color: /^#[0-9a-f]{6}$/i.test(String(o.color || ''))
            ? String(o.color)
            : STATUS_COLORS[(i * 6 + k) % STATUS_COLORS.length],
          color2: /^#[0-9a-f]{6}$/i.test(String(o.color2 || ''))
            ? String(o.color2)
            : (defColor2[o.label] || STATUS_COLORS[(i * 6 + k + 3) % STATUS_COLORS.length])
        };
      })
    };
  });
}

/* ---------------------------------------------------------------- 表情包
   本地表情包（后台自己加）+ 第三方图源（Tenor / Giphy / 自定义接口，服务端代跑，手机不用翻墙） */
const STICKER_FILE = 'stickers.json';
/* 「我的表情」：每个人自己添加了哪些表情包 / 哪些单个表情（微信「我 → 表情」那套） */
const STICKER_USER_FILE = 'stickers-user.json';
let stickerUserCache = null;

function readStickerUser() {
  if (stickerUserCache) return stickerUserCache;
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, STICKER_USER_FILE), 'utf8')); } catch (e) { raw = {}; }
  stickerUserCache = { byUser: (raw && typeof raw.byUser === 'object' && raw.byUser) ? raw.byUser : {} };
  return stickerUserCache;
}

function saveStickerUser() {
  if (!stickerUserCache) return;
  try { writeJson(path.join(DATA_DIR, STICKER_USER_FILE), stickerUserCache); } catch (e) { }
}

/** 某个人的表情库（没设置过就是空的：微信新号也是这样，得自己去商店添加） */
function myStickers(userId) {
  const dbm = readStickerUser();
  const row = dbm.byUser[userId] || {};
  return {
    packs: Array.isArray(row.packs) ? row.packs.map((x) => String(x).slice(0, 24)).slice(0, 40) : [],
    singles: Array.isArray(row.singles) ? row.singles.map((x) => String(x).slice(0, 400)).filter(Boolean).slice(0, 120) : [],
    recent: Array.isArray(row.recent) ? row.recent.map((x) => String(x).slice(0, 400)).filter(Boolean).slice(0, 30) : []
  };
}

function setMyStickers(userId, row) {
  const dbm = readStickerUser();
  dbm.byUser[userId] = row;
  saveStickerUser();
  return row;
}
const STICKER_PROVIDERS = ['off', 'tenor', 'giphy', 'custom'];
const STICKER_PACKS_DEFAULT = [
  { id: 's1', name: '小黄脸', icon: '😀', enabled: true, stickers: ['😀', '😃', '😄', '😁', '😆', '😅', '😂', '🤣', '😊', '😇', '🙂', '😉', '😍', '🥰', '😘', '😋', '😜', '🤪', '🤗', '🤔', '🤨', '😐', '😏', '😒', '🙄', '😴', '😷', '🤒', '🥳', '😎', '🤓', '😭'] },
  { id: 's2', name: '手势', icon: '👍', enabled: true, stickers: ['👍', '👎', '👌', '✌️', '🤞', '🤟', '🤘', '👏', '🙌', '🙏', '💪', '👊', '✊', '🤝', '👋', '☝️', '👆', '👇', '👈', '👉', '🖐️', '✋', '🤙', '🫰'] },
  { id: 's3', name: '爱心', icon: '❤️', enabled: true, stickers: ['❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '💔', '❣️', '💕', '💞', '💓', '💗', '💖', '💘', '💝', '💟', '😻', '🫶'] },
  { id: 's4', name: '动物', icon: '🐱', enabled: true, stickers: ['🐱', '🐶', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🐔', '🐧', '🐦', '🦄', '🐝'] },
  { id: 's5', name: '开心日常', icon: '🎉', enabled: true, stickers: ['🎉', '🎊', '🎁', '🎂', '🍰', '🍺', '🥳', '🍀', '🌈', '☀️', '🌙', '⚡', '🔥', '✨', '💯', '🆗', '🙆', '🙅', '💃', '🕺'] }
];

function normalizeStickers(st) {
  const src = st && typeof st === 'object' ? st : {};
  const packsSrc = Array.isArray(src.packs) && src.packs.length ? src.packs : STICKER_PACKS_DEFAULT;
  const packs = packsSrc.slice(0, 40).map((p, i) => {
    const pack = p && typeof p === 'object' ? p : {};
    const list = Array.isArray(pack.stickers) ? pack.stickers : [];
    return {
      id: String(pack.id || '').slice(0, 24) || ('s' + (i + 1)),
      name: String(pack.name == null ? '' : pack.name).trim().slice(0, 12) || ('表情包' + (i + 1)),
      icon: String(pack.icon == null ? '' : pack.icon).trim().slice(0, 8) || '😀',
      enabled: pack.enabled === undefined ? true : !!pack.enabled,
      stickers: list.map((x) => String(x == null ? '' : x).trim().slice(0, 400)).filter(Boolean).slice(0, 120)
    };
  });
  const tp = src.thirdParty && typeof src.thirdParty === 'object' ? src.thirdParty : {};
  return {
    packs: packs,
    thirdParty: {
      provider: STICKER_PROVIDERS.indexOf(tp.provider) >= 0 ? tp.provider : 'off',
      apiKey: String(tp.apiKey || '').slice(0, 200),
      urlTemplate: String(tp.urlTemplate || '').slice(0, 500),
      limit: Math.min(50, Math.max(4, Number(tp.limit) || 24))
    }
  };
}

/** 第三方返回统一解析成 [{ id, url, title }] */
function parseThirdParty(provider, data) {
  const out = [];
  const push = (url, title) => {
    if (url && /^https?:\/\//i.test(url)) out.push({ id: 'x' + out.length, url: url, title: String(title || '表情').slice(0, 40) });
  };
  try {
    if (provider === 'tenor' && data && Array.isArray(data.results)) {
      data.results.forEach((r) => {
        const f = r.media_formats || {};
        push((f.tinygif || f.gif || f.mediumgif || {}).url, r.content_description || r.title);
      });
    } else if (provider === 'giphy' && data && Array.isArray(data.data)) {
      data.data.forEach((g) => {
        const im = g.images || {};
        push((im.fixed_height || im.downsized || im.original || {}).url, g.title);
      });
    } else {
      const found = [];
      const walk = (node, depth) => {
        if (found.length || depth > 4 || !node) return;
        if (Array.isArray(node)) {
          const objs = node.filter((n) => n && typeof n === 'object');
          if (objs.length && objs.some((o) => o.url || o.image || o.imageUrl || (o.images && typeof o.images === 'object'))) { found.push(objs); return; }
          node.slice(0, 3).forEach((n) => walk(n, depth + 1));
          return;
        }
        if (typeof node === 'object') Object.keys(node).forEach((k) => walk(node[k], depth + 1));
      };
      walk(data, 0);
      (found[0] || []).forEach((o) => {
        const url = o.url || o.image || o.imageUrl || (o.images ? ((o.images.fixed_height || o.images.original || {}).url) : '');
        push(url, o.title || o.description || o.name);
      });
    }
  } catch (err) { /* 结构不认就当没结果 */ }
  return out.slice(0, 50);
}

/** 拼第三方请求地址（自定义接口支持 {q} {key} {limit} 占位符） */
function thirdPartyUrl(tp, keyword) {
  const q = encodeURIComponent(keyword || '开心');
  if (tp.provider === 'tenor') {
    return 'https://tenor.googleapis.com/v2/search?q=' + q + '&key=' + encodeURIComponent(tp.apiKey) + '&limit=' + tp.limit + '&media_filter=tinygif,gif';
  }
  if (tp.provider === 'giphy') {
    return 'https://api.giphy.com/v1/gifs/search?api_key=' + encodeURIComponent(tp.apiKey) + '&q=' + q + '&limit=' + tp.limit + '&rating=pg-13';
  }
  if (tp.provider === 'custom' && tp.urlTemplate) {
    return tp.urlTemplate.replace(/\{q\}/g, q).replace(/\{key\}/g, encodeURIComponent(tp.apiKey)).replace(/\{limit\}/g, tp.limit);
  }
  return '';
}

function normalizeGifts(list) {
  const src = Array.isArray(list) && list.length ? list : DEFAULT_GIFTS;
  return src.slice(0, 120).map((it, i) => {
    const g = it && typeof it === 'object' ? it : {};
    const price = Number(g.price);
    return {
      id: String(g.id || '').slice(0, 24) || ('g' + (i + 1)),
      name: String(g.name == null ? '' : g.name).trim().slice(0, 12) || ('礼物' + (i + 1)),
      icon: String(g.icon == null ? '' : g.icon).trim().slice(0, 8) || '🎁',
      price: isFinite(price) && price >= 0 ? Math.min(999999, Math.round(price)) : 1,
      category: String(g.category == null ? '' : g.category).trim().slice(0, 8) || '通用',
      enabled: g.enabled === undefined ? true : !!g.enabled
    };
  });
}

/* 发现页那几行洗干净：名称、图标、颜色、动作、分组、顺序、开关都以后台为准 */
function normalizeDiscover(list) {
  const src = Array.isArray(list) && list.length ? list : DEFAULT_DISCOVER;
  return normalizeRowList(src, DISCOVER_ACTIONS, DEFAULT_DISCOVER);
}

/** 发现页 / 我页 这类「一行一行」的配置，洗干净的逻辑是一样的 */
function normalizeRowList(list, actions, defaults) {
  const src = Array.isArray(list) && list.length ? list : defaults;
  return src.slice(0, 30).map((it, i) => {
    const item = it && typeof it === 'object' ? it : {};
    const label = String(item.label == null ? '' : item.label).trim().slice(0, 12) || ('功能' + (i + 1));
    const action = actions.indexOf(item.action) >= 0 ? item.action : actions[actions.length - 1];
    const color = /^#[0-9a-fA-F]{6}$/.test(String(item.color || '')) ? String(item.color) : '#4A90D9';
    let group = Number(item.group);
    if (!Number.isFinite(group) || group < 1) group = i + 1;
    return {
      id: String(item.id || '').slice(0, 24) || ('d' + (i + 1) + '_' + Date.now().toString(36).slice(-4)),
      label: label,
      icon: String(item.icon || '').slice(0, 60),          // 图标标识（UI 图标页里那些 key）
      svg: String(item.svg || '').slice(0, 20000),          // 也可以直接塞一段 svg
      color: color,
      action: action,
      group: Math.round(group),
      enabled: item.enabled === undefined ? true : !!item.enabled
    };
  });
}

function normalizeMePage(list) {
  const src = Array.isArray(list) && list.length ? list : DEFAULT_ME_PAGE;
  return normalizeRowList(src, ME_ACTIONS, DEFAULT_ME_PAGE);
}

/* 账单页样式洗干净（图标大小、字号、行高） */
function normalizeBillsPage(cfg) {
  const src = cfg && typeof cfg === 'object' ? cfg : {};
  const st = src.style && typeof src.style === 'object' ? src.style : {};
  const def = DEFAULT_BILLS_PAGE.style;
  const faqSrc = Array.isArray(src.faq) ? src.faq : DEFAULT_BILLS_PAGE.faq;
  const faq = faqSrc.slice(0, 10).map((it) => {
    const o = it && typeof it === 'object' ? it : {};
    return {
      q: String(o.q == null ? '' : o.q).trim().slice(0, 60),
      a: String(o.a == null ? '' : o.a).trim().slice(0, 300)
    };
  }).filter((x) => x.q && x.a);
  const num = (v, lo, hi, fallback) => {
    const n = Number(v);
    if (!Number.isFinite(n)) return fallback;
    return Math.min(hi, Math.max(lo, Math.round(n * 10) / 10));
  };
  return {
    faq: faq,
    style: {
      iconSize: num(st.iconSize, 28, 80, def.iconSize),
      titleSize: num(st.titleSize, 11, 30, def.titleSize),
      timeSize: num(st.timeSize, 9, 24, def.timeSize),
      amountSize: num(st.amountSize, 10, 30, def.amountSize),
      curSize: num(st.curSize, 0, 60, def.curSize),
      amountWeight: num(st.amountWeight, 200, 800, def.amountWeight),
      showCur: st.showCur === undefined ? def.showCur : !!st.showCur,
      monthSize: num(st.monthSize, 11, 28, def.monthSize),
      sumSize: num(st.sumSize, 9, 24, def.sumSize),
      rowHeight: num(st.rowHeight, 56, 140, def.rowHeight)
    }
  };
}

/* 零钱页配置洗干净：文案、两个按钮、底部链接、说明、样式 */
function normalizeBalancePage(cfg) {
  const src = cfg && typeof cfg === 'object' ? cfg : {};
  const def = DEFAULT_BALANCE_PAGE;
  const str = (v, len, fallback) => {
    const s = String(v == null ? '' : v).trim().slice(0, len);
    return s || fallback;
  };
  const btn = (o, fallback) => {
    const b = o && typeof o === 'object' ? o : {};
    return {
      label: str(b.label, 12, fallback.label),
      action: BALANCE_ACTIONS.indexOf(b.action) >= 0 ? b.action : fallback.action
    };
  };
  const linksSrc = Array.isArray(src.links) && src.links.length ? src.links : def.links;
  const links = linksSrc.slice(0, 4).map((it, i) => {
    const o = it && typeof it === 'object' ? it : {};
    return {
      id: String(o.id || '').slice(0, 24) || ('bl' + (i + 1)),
      label: str(o.label, 12, '链接' + (i + 1)),
      action: BALANCE_ACTIONS.indexOf(o.action) >= 0 ? o.action : 'soon',
      enabled: o.enabled === undefined ? true : !!o.enabled
    };
  });
  const st = src.style && typeof src.style === 'object' ? src.style : {};
  const faqSrc = Array.isArray(src.faq) ? src.faq : def.faq;
  const faq = faqSrc.slice(0, 10).map((it) => {
    const o = it && typeof it === 'object' ? it : {};
    return {
      q: String(o.q == null ? '' : o.q).trim().slice(0, 60),
      a: String(o.a == null ? '' : o.a).trim().slice(0, 300)
    };
  }).filter((x) => x.q && x.a);
  const num = (v, lo, hi, fallback) => {
    const n = Number(v);
    if (!Number.isFinite(n)) return fallback;
    return Math.min(hi, Math.max(lo, Math.round(n * 10) / 10));
  };
  const col = (v, fallback) => (/^#[0-9a-fA-F]{6}$/.test(String(v || '')) ? String(v) : fallback);
  const style = {
    bg: col(st.bg, def.style.bg),
    circleSize: num(st.circleSize, 40, 160, def.style.circleSize),
    circleColor: col(st.circleColor, def.style.circleColor),
    yenSize: num(st.yenSize, 12, 80, def.style.yenSize),
    yenColor: col(st.yenColor, def.style.yenColor),
    titleSize: num(st.titleSize, 11, 30, def.style.titleSize),
    amountSize: num(st.amountSize, 20, 120, def.style.amountSize),
    curSize: num(st.curSize, 0, 120, def.style.curSize),
    noteSize: num(st.noteSize, 9, 26, def.style.noteSize),
    noteColor: col(st.noteColor, def.style.noteColor),
    padTop: num(st.padTop, 0, 200, def.style.padTop),
    gapTitle: num(st.gapTitle, 0, 100, def.style.gapTitle),
    gapAmount: num(st.gapAmount, 0, 100, def.style.gapAmount),
    gapNote: num(st.gapNote, 0, 100, def.style.gapNote),
    btnWidth: num(st.btnWidth, 100, 360, def.style.btnWidth),
    btnHeight: num(st.btnHeight, 32, 80, def.style.btnHeight),
    btnRadius: num(st.btnRadius, 0, 30, def.style.btnRadius),
    rechargeBg: col(st.rechargeBg, def.style.rechargeBg),
    rechargeInk: col(st.rechargeInk, def.style.rechargeInk),
    withdrawBg: col(st.withdrawBg, def.style.withdrawBg),
    withdrawInk: col(st.withdrawInk, def.style.withdrawInk),
    linkSize: num(st.linkSize, 9, 24, def.style.linkSize),
    linkColor: col(st.linkColor, def.style.linkColor),
    footerSize: num(st.footerSize, 9, 24, def.style.footerSize),
    footerColor: col(st.footerColor, def.style.footerColor)
  };
  return {
    navTitle: str(src.navTitle, 12, def.navTitle),
    title: str(src.title, 12, def.title),
    detailLabel: str(src.detailLabel, 12, def.detailLabel),
    note: String(src.note == null ? '' : src.note).trim().slice(0, 60),
    recharge: btn(src.recharge, def.recharge),
    withdraw: btn(src.withdraw, def.withdraw),
    links: links,
    footer: src.footer === undefined ? def.footer : String(src.footer == null ? '' : src.footer).trim().slice(0, 60),
    faq: faq,
    style: style
  };
}

/* 钱包页配置洗干净：标题、右上角按钮、两张卡的格子、底部链接、样式 */
/* ============================================================
   IM 模块（后台「IM 模块」那一页能改）
   聊天总开关、各类消息允不允许、陌生人能不能私聊、撤回时限、
   单条字数上限、能不能建群 / 群人数上限、在线状态显示。
   改完存 data/im.json，App 侧发消息时会按这里的规则拦。
   ============================================================ */
const IM_FILE = 'im.json';
const DEFAULT_IM = {
  enabled: true,          // 聊天总开关
  text: true,             // 文字
  image: true,            // 图片
  audio: true,            // 语音
  video: true,            // 视频/视频通话
  file: true,             // 文件
  location: true,         // 位置
  redpacket: true,        // 红包
  transfer: true,         // 转账
  gift: true,             // 礼物
  allowStranger: false,   // 不是好友也能私聊
  recallMinutes: 2,       // 多久内能撤回（0 = 不许撤回）
  maxTextLen: 4000,       // 单条文字最多多少字
  allowCreateGroup: true, // 允许建群
  maxGroupMembers: 100,   // 群人数上限
  onlineStatus: true,     // 显示在线状态
  readReceipt: false      // 已读回执
};

function normalizeIm(src) {
  const s = src && typeof src === 'object' ? (src.im && typeof src.im === 'object' ? src.im : src) : {};
  const out = {};
  Object.keys(DEFAULT_IM).forEach((k) => {
    const def = DEFAULT_IM[k];
    const v = s[k];
    if (typeof def === 'boolean') out[k] = v === undefined ? def : !!v;
    else out[k] = (v === undefined || v === null || isNaN(Number(v))) ? def
      : Math.max(0, Math.min(k === 'maxTextLen' ? 20000 : 10000, Math.round(Number(v))));
  });
  return out;
}

function readIm() {
  try {
    return normalizeIm(readJson(path.join(DATA_DIR, IM_FILE), DEFAULT_IM));
  } catch (e) {
    return Object.assign({}, DEFAULT_IM);
  }
}

function saveIm(patch) {
  const next = normalizeIm(Object.assign({}, readIm(), patch || {}));
  writeJson(path.join(DATA_DIR, IM_FILE), next);
  return next;
}

/* 发消息前按 IM 模块的开关拦一道：返回错误文案，允许就返回 '' */
function imKindBlocked(kind) {
  const im = readIm();
  if (!im.enabled) return '管理员暂时关闭了聊天';
  const map = {
    text: im.text, image: im.image, audio: im.audio, file: im.file,
    location: im.location, redpacket: im.redpacket, transfer: im.transfer, gift: im.gift
  };
  if (map[kind] === false) return '这个类型的消息被管理员关闭了';
  if (kind === 'file' && im.video === false) {
    /* 视频文件也归「视频」那一栏管 */
  }
  return '';
}

function normalizeWallet(cfg) {
  const src = cfg && typeof cfg === 'object' ? cfg : {};
  const def = DEFAULT_WALLET;
  const title = String(src.title == null ? '' : src.title).trim().slice(0, 12) || def.title;
  const rightSrc = src.right && typeof src.right === 'object' ? src.right : {};
  const right = {
    label: String(rightSrc.label == null ? '' : rightSrc.label).trim().slice(0, 12) || def.right.label,
    action: WALLET_ACTIONS.indexOf(rightSrc.action) >= 0 ? rightSrc.action : def.right.action
  };

  const normItem = (it, i, gi) => {
    const o = it && typeof it === 'object' ? it : {};
    return {
      id: String(o.id || '').slice(0, 24) || ('w' + (gi + 1) + '_' + (i + 1)),
      label: String(o.label == null ? '' : o.label).trim().slice(0, 12) || ('项目' + (i + 1)),
      value: String(o.value == null ? '' : o.value).trim().slice(0, 24),
      valueKind: o.valueKind === 'balance' ? 'balance' : '',
      note: String(o.note == null ? '' : o.note).trim().slice(0, 24),
      icon: String(o.icon || '').slice(0, 60),
      svg: String(o.svg || '').slice(0, 20000),
      color: /^#[0-9a-fA-F]{6}$/.test(String(o.color || '')) ? String(o.color) : '#1180E0',
      action: WALLET_ACTIONS.indexOf(o.action) >= 0 ? o.action : 'soon',
      mask: o.mask === undefined ? true : !!o.mask,     // 这一行的金额要不要打星号
      enabled: o.enabled === undefined ? true : !!o.enabled
    };
  };
  const groupsSrc = Array.isArray(src.groups) && src.groups.length ? src.groups : def.groups;
  const groups = groupsSrc.slice(0, 12).map((g, gi) => {
    const g0 = g && typeof g === 'object' ? g : {};
    return {
      id: String(g0.id || '').slice(0, 24) || ('wg' + (gi + 1)),
      enabled: g0.enabled === undefined ? true : !!g0.enabled,
      items: (Array.isArray(g0.items) ? g0.items : []).slice(0, 20).map((it, i) => normItem(it, i, gi))
    };
  });

  const footerSrc = Array.isArray(src.footer) && src.footer.length ? src.footer : def.footer;
  const footer = footerSrc.slice(0, 6).map((it, i) => {
    const o = it && typeof it === 'object' ? it : {};
    return {
      id: String(o.id || '').slice(0, 24) || ('wf' + (i + 1)),
      label: String(o.label == null ? '' : o.label).trim().slice(0, 12) || ('链接' + (i + 1)),
      action: WALLET_ACTIONS.indexOf(o.action) >= 0 ? o.action : 'soon',
      enabled: o.enabled === undefined ? true : !!o.enabled
    };
  });

  const st = src.style && typeof src.style === 'object' ? src.style : {};
  const num = (v, lo, hi, fallback) => {
    const n = Number(v);
    if (!Number.isFinite(n)) return fallback;
    return Math.min(hi, Math.max(lo, Math.round(n * 10) / 10));
  };
  const col = (v, fallback) => (/^#[0-9a-fA-F]{6}$/.test(String(v || '')) ? String(v) : fallback);
  const style = {
    rowHeight: num(st.rowHeight, 40, 100, def.style.rowHeight),
    iconSize: num(st.iconSize, 12, 40, def.style.iconSize),
    iconLeft: num(st.iconLeft, 0, 60, def.style.iconLeft),
    textLeft: num(st.textLeft, 20, 120, def.style.textLeft),
    rightInset: num(st.rightInset, 0, 60, def.style.rightInset),
    labelSize: num(st.labelSize, 11, 30, def.style.labelSize),
    valueSize: num(st.valueSize, 10, 30, def.style.valueSize),
    noteSize: num(st.noteSize, 9, 26, def.style.noteSize),
    footerSize: num(st.footerSize, 9, 26, def.style.footerSize),
    groupGap: num(st.groupGap, 0, 40, def.style.groupGap),
    dividerInset: num(st.dividerInset, 0, 200, def.style.dividerInset),
    labelColor: /^#[0-9a-fA-F]{6}$/.test(String(st.labelColor || '')) ? String(st.labelColor) : '',
    valueColor: col(st.valueColor, def.style.valueColor),
    noteColor: col(st.noteColor, def.style.noteColor),
    footerColor: col(st.footerColor, def.style.footerColor),
    curSize: num(st.curSize, 0, 120, def.style.curSize)
  };
  style.maskAmount = st.maskAmount === undefined ? def.style.maskAmount : !!st.maskAmount;
  style.maskReveal = st.maskReveal === undefined ? def.style.maskReveal : !!st.maskReveal;
  return { title: title, right: right, groups: groups, footer: footer, style: style };
}

/* 服务页配置洗干净：标题、绿卡两半、每个分类里的格子，全都按后台存的来。
   格子沿用「发现页 / 我页」那一套字段（label / icon / svg / color / action / enabled），
   所以后台的图标选择器、颜色选择器可以直接复用。 */
function normalizeService(cfg) {
  const src = cfg && typeof cfg === 'object' ? cfg : {};
  const def = DEFAULT_SERVICE;
  const title = String(src.title == null ? '' : src.title).trim().slice(0, 12) || def.title;

  const normHalf = (half, fallback) => {
    const it = half && typeof half === 'object' ? half : {};
    return {
      label: String(it.label == null ? '' : it.label).trim().slice(0, 12) || fallback.label,
      sub: String(it.sub == null ? '' : it.sub).trim().slice(0, 30),
      icon: String(it.icon || fallback.icon).slice(0, 60),
      svg: String(it.svg || '').slice(0, 20000),
      action: SERVICE_ACTIONS.indexOf(it.action) >= 0 ? it.action : fallback.action
    };
  };
  const cardSrc = src.card && typeof src.card === 'object' ? src.card : {};
  const card = {
    enabled: cardSrc.enabled === undefined ? true : !!cardSrc.enabled,
    bg: /^#[0-9a-fA-F]{6}$/.test(String(cardSrc.bg || '')) ? String(cardSrc.bg) : def.card.bg,
    left: normHalf(cardSrc.left, def.card.left),
    right: normHalf(cardSrc.right, def.card.right)
  };

  const groupsSrc = Array.isArray(src.groups) && src.groups.length ? src.groups : def.groups;

  /* 底部那块（账单卡 + ⋯ 菜单）的文案：空字符串就回默认值，最多 20 个字 */
  const bSrc = src.bottom && typeof src.bottom === 'object' ? src.bottom : {};
  const btxt = (v, fallback, max) => {
    const s = String(v == null ? '' : v).trim();
    return s ? s.slice(0, max || 20) : fallback;
  };
  const bottom = {
    billTitle: btxt(bSrc.billTitle, def.bottom.billTitle),
    billAll: btxt(bSrc.billAll, def.bottom.billAll),
    billRecharge: btxt(bSrc.billRecharge, def.bottom.billRecharge),
    billEmpty: btxt(bSrc.billEmpty, def.bottom.billEmpty, 40),
    moreRefresh: btxt(bSrc.moreRefresh, def.bottom.moreRefresh),
    moreRecharge: btxt(bSrc.moreRecharge, def.bottom.moreRecharge),
    moreCancel: btxt(bSrc.moreCancel, def.bottom.moreCancel),
    soonTip: btxt(bSrc.soonTip, def.bottom.soonTip, 60)
  };

  /* 样式：数字都夹在合理区间里（后台拖错了也不至于把页面搞烂） */
  const st = src.style && typeof src.style === 'object' ? src.style : {};
  const num = (v, lo, hi, fallback) => {
    const n = Number(v);
    if (!Number.isFinite(n)) return fallback;
    return Math.min(hi, Math.max(lo, Math.round(n * 10) / 10));
  };
  const col = (v, fallback) => (/^#[0-9a-fA-F]{6}$/.test(String(v || '')) ? String(v) : fallback);
  const style = {
    cardImage: String(st.cardImage == null ? '' : st.cardImage).trim().slice(0, 300),
    cardTextColor: col(st.cardTextColor, def.style.cardTextColor),
    cardTextSize: num(st.cardTextSize, 10, 40, def.style.cardTextSize),
    cardSubSize: num(st.cardSubSize, 8, 30, def.style.cardSubSize),
    cardSubOpacity: Math.min(1, Math.max(0, Number.isFinite(Number(st.cardSubOpacity)) ? Number(st.cardSubOpacity) : def.style.cardSubOpacity)),
    iconSize: num(st.iconSize, 14, 60, def.style.iconSize),
    gridTitleSize: num(st.gridTitleSize, 9, 30, def.style.gridTitleSize),
    gridTitleColor: col(st.gridTitleColor, def.style.gridTitleColor),
    gridTextSize: num(st.gridTextSize, 9, 30, def.style.gridTextSize),
    gridTextColor: /^#[0-9a-fA-F]{6}$/.test(String(st.gridTextColor || '')) ? String(st.gridTextColor) : ''
  };
  style.maskAmount = st.maskAmount === undefined ? def.style.maskAmount : !!st.maskAmount;
  style.maskReveal = st.maskReveal === undefined ? def.style.maskReveal : !!st.maskReveal;

  const groups = groupsSrc.slice(0, 20).map((g, gi) => {
    const g0 = g && typeof g === 'object' ? g : {};
    const gdef = def.groups[Math.min(gi, def.groups.length - 1)];
    /* 版块只给「上 / 下」两个值（块与块之间的空隙）；
       行间距、标题行高、每行高、留白这些都取消，回到参考图那套固定值。
       左右一律固定在参考图的 8pt，不提供调节。 */
    const gst = g0.style && typeof g0.style === 'object' ? g0.style : {};
    const gnum = (v, lo, hi) => {
      if (v === undefined || v === null || v === '') return null;
      const n = Number(v);
      if (!Number.isFinite(n)) return null;
      return Math.min(hi, Math.max(lo, Math.round(n * 10) / 10));
    };
    const groupStyle = {
      gapTop: gnum(gst.gapTop, 0, 100),         // 这个版块上面空多少
      gapBottom: gnum(gst.gapBottom, 8, 100)    // 这个版块下面空多少（最少 8，版块不会挨在一起）
    };
    const items = (Array.isArray(g0.items) ? g0.items : []).slice(0, 24).map((it, i) => {
      const o = it && typeof it === 'object' ? it : {};
      return {
        id: String(o.id || '').slice(0, 24) || ('sv' + (gi + 1) + '_' + (i + 1)),
        label: String(o.label == null ? '' : o.label).trim().slice(0, 12) || ('功能' + (i + 1)),
        icon: String(o.icon || '').slice(0, 60),
        svg: String(o.svg || '').slice(0, 20000),
        color: /^#[0-9a-fA-F]{6}$/.test(String(o.color || '')) ? String(o.color) : '#1180E0',
        action: SERVICE_ACTIONS.indexOf(o.action) >= 0 ? o.action : 'soon',
        enabled: o.enabled === undefined ? true : !!o.enabled
      };
    });
    return {
      id: String(g0.id || '').slice(0, 24) || ('sg' + (gi + 1)),
      title: String(g0.title == null ? '' : g0.title).trim().slice(0, 12) || (gdef && gdef.title) || ('分类' + (gi + 1)),
      enabled: g0.enabled === undefined ? true : !!g0.enabled,
      style: groupStyle,
      items: items
    };
  });
  return { title: title, card: card, bottom: bottom, style: style, groups: groups };
}

/* 把后台传来的 ＋ 面板配置洗干净（名称、图标、动作、开关、顺序都以这里为准） */
function normalizePlusItems(list) {
  const src = Array.isArray(list) && list.length ? list : DEFAULT_PLUS_ITEMS;
  return src.slice(0, 40).map((it, i) => {
    const item = it && typeof it === 'object' ? it : {};
    const label = String(item.label == null ? '' : item.label).trim().slice(0, 12) || ('功能' + (i + 1));
    const icon = PLUS_ICONS.indexOf(item.icon) >= 0 ? item.icon : 'star';
    const action = PLUS_ACTIONS.indexOf(item.action) >= 0 ? item.action : 'none';
    return {
      id: String(item.id || '').slice(0, 24) || ('p' + (i + 1)),
      label: label,
      icon: icon,
      action: action,
      enabled: item.enabled === undefined ? true : !!item.enabled
    };
  });
}

/* 快捷按钮（输入框上面那一排）的规范化 */
function normalizeQuickItems(list) {
  const src = Array.isArray(list) && list.length ? list : DEFAULT_QUICK_ITEMS;
  return src.slice(0, 12).map((it, i) => {
    const item = it && typeof it === 'object' ? it : {};
    const label = String(item.label == null ? '' : item.label).trim().slice(0, 8) || ('按钮' + (i + 1));
    const action = QUICK_ACTIONS.indexOf(item.action) >= 0 ? item.action : 'none';
    return {
      id: String(item.id || '').slice(0, 24) || ('q' + (i + 1)),
      label: label,
      action: action,
      enabled: item.enabled === undefined ? true : !!item.enabled
    };
  });
}

/* 「＋」按钮的外观：颜色（#RRGGBB，空 = 跟主题）/ 大小（0 = 默认）/ 图片（自己上传的一张图） */
function normalizePlusButton(cfg) {
  const c = cfg && typeof cfg === 'object' ? cfg : {};
  const raw = String(c.color || '').trim();
  const img = String(c.image || '').trim().slice(0, 500);
  return {
    color: /^#?[0-9a-fA-F]{6}$/.test(raw) ? (raw[0] === '#' ? raw : ('#' + raw)) : '',
    size: Math.max(0, Math.min(44, Number(c.size) || 0)),
    image: (/^https?:\/\//i.test(img) || /^\/uploads\/[A-Za-z0-9._-]+$/.test(img)) ? img : ''
  };
}
const DEFAULT_BRANDING = {
  appName: 'CHRIS Chat',
  logo: '',
  chatBackground: '',
  splash: '',                 // 启动页图片（后台可换；空 = 用 App 包里那张）
  fontFamily: '',
  fontName: '',
  fontUrl: '',
  fontScale: 1,
  accentColor: '',
  textColor: '',
  iceServers: '',
  icons: { chats: '', contacts: '', groups: '', moments: '', account: '' },
  updatedAt: ''
};
const messageCache = new Map();
/* CHRIS_BURN_V1 观察名单：这几条会话里还有「带小火苗」的消息，定时器要盯着它们
   （哪怕开关后来被关掉，也要把已经发出去的那几条烧干净）。 */
const burnWatch = new Set();
const BURN_HOLD_MS = 20000;     // CHRIS_BURN_V1 看过 20 秒后焚毁（2026-10-13 用户定）

/** 面对面建群：同一个 4 位数字在有效期内进同一个群 */
const FACE_ROOM_WINDOW_MS = 3 * 60 * 1000;
function pruneFaceRooms() {
  const t = Date.now();
  const kept = db.faceRooms.filter((r) => r.expiresAt > t);
  if (kept.length !== db.faceRooms.length) db.faceRooms = kept;
  return db.faceRooms;
}

/* ---------------------------------------------------------------- 敏感字段加密
   手机号、实名姓名落盘不留明文：AES-256-GCM，密钥由 secret.key 派生（HMAC("pii")）。
   内存里始终是明文，所以登录 / 查重 / 后台搜索的逻辑一行都不用改。
   老数据（明文）自动兼容：读到就当明文用，下次保存自动变成密文。 */
const PII_PREFIX = 'enc1:';
function piiKey() {
  return crypto.createHmac('sha256', String(db.secret || 'chris')).update('pii').digest();
}
function sealPii(v) {
  const s0 = String(v == null ? '' : v);
  if (!s0) return '';
  if (s0.startsWith(PII_PREFIX)) return s0;            // 已经是密文就别再套一层
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', piiKey(), iv);
  const ct = Buffer.concat([c.update(Buffer.from(s0, 'utf8')), c.final()]);
  return PII_PREFIX + iv.toString('base64') + ':' + c.getAuthTag().toString('base64') + ':' + ct.toString('base64');
}
function openPii(v) {
  const s0 = String(v == null ? '' : v);
  if (!s0) return '';
  if (!s0.startsWith(PII_PREFIX)) return s0;           // 老数据：明文原样返回
  const parts = s0.slice(PII_PREFIX.length).split(':');
  if (parts.length !== 3) return '';
  try {
    const iv = Buffer.from(parts[0], 'base64');
    const tag = Buffer.from(parts[1], 'base64');
    const ct = Buffer.from(parts[2], 'base64');
    const d = crypto.createDecipheriv('aes-256-gcm', piiKey(), iv);
    d.setAuthTag(tag);
    return Buffer.concat([d.update(ct), d.final()]).toString('utf8');
  } catch (err) { return ''; }
}
function loadStore() {
  ensureDirs();
  const users = readJson(path.join(DATA_DIR, 'users.json'), { users: [] });
  const friends = readJson(path.join(DATA_DIR, 'friendships.json'), { friendships: [] });
  const chats = readJson(path.join(DATA_DIR, 'chats.json'), { chats: [] });
  const reads = readJson(path.join(DATA_DIR, 'reads.json'), { reads: {} });
  const delivered = readJson(path.join(DATA_DIR, 'delivered.json'), { delivered: {} });
  const moments = readJson(path.join(DATA_DIR, 'moments.json'), { moments: [] });
  const momentViews = readJson(path.join(DATA_DIR, 'moment-views.json'), { views: {} });
  const momentNotices = readJson(path.join(DATA_DIR, 'moment-notices.json'), { items: [], seen: {} });
  const announcements = readJson(path.join(DATA_DIR, 'announcements.json'), { announcements: [] });
  const branding = readJson(path.join(DATA_DIR, BRANDING_FILE), { branding: null });
  const plusPanel = readJson(path.join(DATA_DIR, PLUSPANEL_FILE), { items: null });
  const gifts = readJson(path.join(DATA_DIR, GIFTS_FILE), { gifts: null });
  const stickers = readJson(path.join(DATA_DIR, STICKER_FILE), { stickers: null });
  const statuses = readJson(path.join(DATA_DIR, STATUS_FILE), { categories: null });
  const discover = readJson(path.join(DATA_DIR, DISCOVER_FILE), { items: null });
  const mePage = readJson(path.join(DATA_DIR, ME_PAGE_FILE), { items: null });
  const service = readJson(path.join(DATA_DIR, SERVICE_FILE), { service: null });
  const wallet = readJson(path.join(DATA_DIR, WALLET_FILE), { wallet: null });
  const balancePage = readJson(path.join(DATA_DIR, BALANCE_FILE), { page: null });
  const billsPage = readJson(path.join(DATA_DIR, BILLS_FILE), { page: null });
  const faceRooms = readJson(path.join(DATA_DIR, 'face-rooms.json'), { rooms: [] });
  const transfers = readJson(path.join(DATA_DIR, 'transfers.json'), { transfers: [] });
  const redpackets = readJson(path.join(DATA_DIR, 'redpackets.json'), { redpackets: [] });
  const security = readJson(path.join(DATA_DIR, 'logins.json'), { logins: [], events: [] });
  db.users = Array.isArray(users.users) ? users.users : [];
  /* 在线客服（kefu）是「服务账号」：名片上显示官方账号，但不参与给所有人建会话的机器人循环 */
  db.users.forEach((u) => { if (u.username === 'kefu') { u.bot = true; u.service = true; } });
  ensureGenders();
  db.friendships = Array.isArray(friends.friendships) ? friends.friendships : [];
  db.chats = Array.isArray(chats.chats) ? chats.chats : [];
  db.reads = reads.reads && typeof reads.reads === 'object' ? reads.reads : {};
  /* 投递回执：客户端收到消息就回一条 ack，这里记「这个人收到哪个会话的第几条」。
     和 reads（已读游标）分开存：delivered=收到了没，reads=看了没。
     后台「消息投递日志」靠这两个区分 未送达 / 已送达 / 已读（微信也是这么分的）。 */
  db.delivered = delivered.delivered && typeof delivered.delivered === 'object' ? delivered.delivered : {};
  /* 清空聊天记录：记到哪一条为止（只影响清空的那个人，别人不受影响） */
  db.cleared = reads.cleared && typeof reads.cleared === 'object' ? reads.cleared : {};
  db.moments = Array.isArray(moments.moments) ? moments.moments : [];
  db.momentViews = momentViews.views && typeof momentViews.views === 'object' ? momentViews.views : {};
  db.momentNotices = Array.isArray(momentNotices.items) ? momentNotices.items : [];
  db.momentNoticeSeen = momentNotices.seen && typeof momentNotices.seen === 'object' ? momentNotices.seen : {};
  db.announcements = Array.isArray(announcements.announcements) ? announcements.announcements : [];
  db.faceRooms = (Array.isArray(faceRooms.rooms) ? faceRooms.rooms : []).filter((r) => r && r.code && r.chatId);
  db.transfers = Array.isArray(transfers.transfers) ? transfers.transfers : [];
  /* 老的红包（早期一对一那套：只有 amount / toId）直接丢掉 —— 结构和规则都不一样，
     留着只会在聊天里画出错的卡片。红包记录本来就是一次性消费，不存在补数据的必要。 */
  db.redpackets = (Array.isArray(redpackets.redpackets) ? redpackets.redpackets : [])
    .filter((r) => r && typeof r === 'object' && Array.isArray(r.claims) && r.total != null);
  db.security = {
    logins: Array.isArray(security.logins) ? security.logins : [],
    events: Array.isArray(security.events) ? security.events : []
  };
  db.branding = branding.branding && typeof branding.branding === 'object'
    ? Object.assign({}, DEFAULT_BRANDING, branding.branding, {
      icons: Object.assign({}, DEFAULT_BRANDING.icons, branding.branding.icons || {})
    })
    : JSON.parse(JSON.stringify(DEFAULT_BRANDING));
  const badgeCfg = readJson(path.join(DATA_DIR, 'badges.json'), { badges: null });
  db.badges = Object.assign({
    chats: 'auto', contacts: 'auto', discover: 'auto', me: 'off', newFriends: 'auto', momentsRow: 'auto'
  }, (badgeCfg && badgeCfg.badges) || {});
  db.plusPanel = normalizePlusItems(plusPanel.items);
  db.quickBar = normalizeQuickItems(plusPanel.quick);
  db.plusButton = normalizePlusButton(plusPanel.plus);
  db.gifts = normalizeGifts(gifts.gifts);
  db.stickers = normalizeStickers(stickers.stickers);
  db.statuses = normalizeStatus(statuses.categories);
  db.discover = normalizeDiscover(discover.items);
  db.mePage = normalizeMePage(mePage.items);
  db.chatBg = normalizeChatBg(readJson(path.join(DATA_DIR, CHAT_BG_FILE), null));
  db.service = normalizeService(service.service);
  db.wallet = normalizeWallet(wallet.wallet);
  db.balancePage = normalizeBalancePage(balancePage.page);
  db.billsPage = normalizeBillsPage(billsPage.page);

  const adminFile = path.join(DATA_DIR, ADMIN_FILE_NAME);
  const tablesFile = path.join(DATA_DIR, 'tables.json');
if (fs.existsSync(tablesFile)) {
  try { const parsed = JSON.parse(fs.readFileSync(tablesFile, 'utf8')); if (parsed && typeof parsed === 'object') db.tables = parsed; } catch (err) { /* 忽略 */ }
}

if (fs.existsSync(adminFile)) {
    try {
      const parsed = JSON.parse(fs.readFileSync(adminFile, 'utf8'));
      if (parsed && parsed.hash && parsed.salt && parsed.secret) adminAuth = parsed;
    } catch (err) { adminAuth = null; }
  }
  if (!adminAuth) {
    adminAuth = makeSecretRecord(DEFAULT_ADMIN_PASSWORD);
    fs.writeFileSync(adminFile, JSON.stringify(adminAuth, null, 2), 'utf8');
    adminJustCreated = true;
  }

  const secretFile = path.join(DATA_DIR, 'secret.key');
  if (fs.existsSync(secretFile)) {
    db.secret = fs.readFileSync(secretFile, 'utf8').trim();
  } else {
    db.secret = crypto.randomBytes(32).toString('hex');
    fs.writeFileSync(secretFile, db.secret, 'utf8');
  }
  /* 敏感字段：磁盘上是密文，内存里换成明文（登录/查重/后台搜索照旧） */
  db.users.forEach((u) => {
    if (!u || typeof u !== 'object') return;
    if (typeof u.phone === 'string' && u.phone) u.phone = openPii(u.phone);
    if (typeof u.realName === 'string' && u.realName) u.realName = openPii(u.realName);
  });
}

/* 保存时把手机号 / 实名姓名加密（内存里仍是明文） */
const saveUsers = () => writeJson(path.join(DATA_DIR, 'users.json'), {
  users: db.users.map((u) => {
    if (!u || typeof u !== 'object') return u;
    const c = Object.assign({}, u);
    if (typeof c.phone === 'string' && c.phone) c.phone = sealPii(c.phone);
    if (typeof c.realName === 'string' && c.realName) c.realName = sealPii(c.realName);
    return c;
  })
});
const saveFriendships = () => writeJson(path.join(DATA_DIR, 'friendships.json'), { friendships: db.friendships });
const saveChats = () => writeJson(path.join(DATA_DIR, 'chats.json'), { chats: db.chats });
const saveReads = () => writeJson(path.join(DATA_DIR, 'reads.json'), { reads: db.reads, cleared: db.cleared || {} });
const saveDelivered = () => writeJson(path.join(DATA_DIR, 'delivered.json'), { delivered: db.delivered });
/* 高频写入用这两个：先打标记，攒到定时器里再落盘（压测发现每发一条消息
   都重写 chats.json/reads.json 是最大瓶颈，1.5 秒合并一次完全够用）。 */
let chatsDirty = false;
let readsDirty = false;
let deliveredDirty = false;
setInterval(() => {
  try {
    if (chatsDirty) { chatsDirty = false; saveChats(); }
    if (readsDirty) { readsDirty = false; saveReads(); }
    if (deliveredDirty) { deliveredDirty = false; saveDelivered(); }
  } catch (err) { /* 忽略 */ }
}, 1500).unref();

/* CHRIS_BURN_TIMER_V1 阅后即焚：**服务端自己**每 15 秒扫一遍
   光靠客户端来扫是不够的 —— 两边都退到后台、或者把聊天页关掉，就谁都不扫了，
   到点的消息会一直挂在屏幕上（用户反复报的「阅后即焚消息依旧在」就是这个）。
   这里自己扫：谁的已读游标过了那条就算「已看过」，看过满 1 分钟销毁；
   兜底是消息本身超过 5 分钟也销毁。销毁后推给双方，界面立刻收走。 */
function burnSweepAll() {
  const nowTs = Date.now();
  const HOLD = BURN_HOLD_MS;                            // 看过 20 秒后焚毁（用户定）
  (db.chats || []).forEach((chat) => {
    if (!chat) return;
    /* 开着开关的，或者「里面还有带小火苗的消息」的（开关后来关掉了也得把这几条烧干净）。 */
    if (!chat.burn && !burnWatch.has(chat.id)) return;
    const list = loadMessages(chat.id);
    if (!list || !list.length) return;
    const gone = [];
    list.forEach((m) => {
      if (!m || !m.burn) return;
      /* 「有人看过了」：客户端上报的 seenAt，或者谁的已读游标已经过了这一条 */
      if (!m.seenAt) {
        const read = (chat.memberIds || []).some((id) => id !== m.senderId
          && ((db.reads[id] && db.reads[id][chat.id]) || 0) >= (m.seq || 0));
        if (read) m.seenAt = nowTs;
      }
      const born = Date.parse(m.createdAt) || 0;
      /* 到点就删（真实删：内存那条数组原地 splice + 写文件）。
         兜底：消息本身超过 5 分钟（对方是旧版本、压根不上报已读）也删。 */
      if ((m.seenAt && nowTs - m.seenAt >= HOLD) || (born && nowTs - born > 5 * 60 * 1000)) {
        gone.push(m.id);
      }
    });
    /* 这一屏已经没有小火苗了 → 从观察名单里拿掉 */
    if (!gone.length && !list.some((m) => m && m.burn)) burnWatch.delete(chat.id);
    if (!gone.length) return;
    const goneSet = {};
    gone.forEach((id) => { goneSet[id] = 1; });
    /* ⚠ 必须**原地删**（loadMessages 返回的就是缓存里那个数组）：
       filter 出新数组写文件的话缓存里还在，每 15 秒又会「销毁」同一批 —— 界面就一直跳。 */
    for (let i = list.length - 1; i >= 0; i--) {
      if (goneSet[list[i].id]) list.splice(i, 1);
    }
    saveMessagesFile(chat.id, list);
    if (!list.some((m) => m && m.burn)) burnWatch.delete(chat.id);
    (chat.memberIds || []).forEach((id) => sendTo(id, { type: 'burn', chatId: chat.id, ids: gone }));
    try { callTrace('burn-timer ' + chat.id + ' 销毁=' + gone.length); } catch (e) { }
  });
}
setInterval(() => {
  try { burnSweepAll(); } catch (err) { /* 绝不因为这一下把服务弄挂 */ }
}, 5000).unref();      // 5 秒扫一遍（20 秒的期限不能被扫描间隔拖长）
const saveMoments = () => writeJson(path.join(DATA_DIR, 'moments.json'), { moments: db.moments });
const saveMomentViews = () => writeJson(path.join(DATA_DIR, 'moment-views.json'), { views: db.momentViews });
const saveMomentNotices = () => writeJson(path.join(DATA_DIR, 'moment-notices.json'),
  { items: db.momentNotices.slice(-2000), seen: db.momentNoticeSeen });
const saveAnnouncements = () => writeJson(path.join(DATA_DIR, 'announcements.json'), { announcements: db.announcements });
const saveBranding = () => writeJson(path.join(DATA_DIR, BRANDING_FILE), { branding: db.branding });
const saveBadges = () => writeJson(path.join(DATA_DIR, 'badges.json'), { badges: db.badges });

/* ---------------- 服务器入口表（App 端的「多线路」） ----------------
   主入口连不上时，App 会按这张表自动换地址（换完记住），所以线上线路抽风不用等出新包。
   只写「域名:端口」或「域名」；空行 / 写错的格式自动丢掉。
   顺序 = 优先级：第一行是主入口，后面是备用。 */
const ENDPOINTS_FILE = path.join(DATA_DIR, 'endpoints.json');
const DEFAULT_ENDPOINTS = ['43.242.194.89:5443', '43.242.194.89', 'aa.x8iu.com:5443'];
function normalizeEndpoint(v) {
  let s = String(v == null ? '' : v).trim();
  if (!s) return '';
  s = s.replace(/^https?:\/\//i, '').replace(/\/+$/, '');
  if (s.length > 80) return '';
  if (!/^[A-Za-z0-9.\-]+(:\d{1,5})?$/.test(s)) return '';
  return s;
}
function serverEndpoints() {
  const cfg = readJson(ENDPOINTS_FILE, null);
  const raw = cfg && Array.isArray(cfg.endpoints) ? cfg.endpoints : [];
  const list = raw.map(normalizeEndpoint).filter(Boolean);
  return list.length ? list.slice(0, 6) : DEFAULT_ENDPOINTS.slice();
}
const savePlusPanel = () => writeJson(path.join(DATA_DIR, PLUSPANEL_FILE),
  { items: db.plusPanel, quick: db.quickBar, plus: db.plusButton });
const saveGifts = () => writeJson(path.join(DATA_DIR, GIFTS_FILE), { gifts: db.gifts });
const saveStickers = () => writeJson(path.join(DATA_DIR, STICKER_FILE), { stickers: db.stickers });
const saveStatuses = () => writeJson(path.join(DATA_DIR, STATUS_FILE), { categories: db.statuses });
/** 后台发公告时顺手用系统通知号发一条（开关在「系统通知」里：notice） */
function noticeAll(text, title) {
  try {
    const cfg = readSysNoticeCfg();
    if (!cfg.enabled || cfg.types.notice === 0) return 0;
    let n = 0;
    db.users.forEach((u) => {
      if (!u || u.bot) return;
      sysNotice(u.id, text, title || '公告', 'notice');
      n++;
    });
    callTrace('公告已用系统号发给 ' + n + ' 人');
    return n;
  } catch (e) { return 0; }
}

const saveDiscover = () => writeJson(path.join(DATA_DIR, DISCOVER_FILE), { items: db.discover });
const saveMePage = () => writeJson(path.join(DATA_DIR, ME_PAGE_FILE), { items: db.mePage });
const saveChatBg = () => writeJson(path.join(DATA_DIR, CHAT_BG_FILE), db.chatBg);
const saveService = () => writeJson(path.join(DATA_DIR, SERVICE_FILE), { service: db.service });
const saveWallet = () => writeJson(path.join(DATA_DIR, WALLET_FILE), { wallet: db.wallet });
const saveBalancePage = () => writeJson(path.join(DATA_DIR, BALANCE_FILE), { page: db.balancePage });
const saveBillsPage = () => writeJson(path.join(DATA_DIR, BILLS_FILE), { page: db.billsPage });
const saveFaceRooms = () => writeJson(path.join(DATA_DIR, 'face-rooms.json'), { rooms: db.faceRooms });
const saveTransfers = () => writeJson(path.join(DATA_DIR, 'transfers.json'), { transfers: db.transfers });
const saveRedPackets = () => writeJson(path.join(DATA_DIR, 'redpackets.json'), { redpackets: db.redpackets });
const saveSecurity = () => writeJson(path.join(DATA_DIR, 'logins.json'), { logins: db.security.logins, events: db.security.events });

/* --------------------------------------------------- 朋友圈：追加式写入
   原来每发一条朋友圈，就把「全部动态」整体重写一遍 moments.json。
   动态一多（几千上万条）光写文件就把磁盘写爆、发一条要几百毫秒。
   现在新动态只往 moments-log.jsonl 追加一行（几 KB），
   下次开服时把日志并回 moments.json 再清空日志（合并只做一次，不占正常请求）。 */
const MOMENTS_LOG = 'moments-log.jsonl';
const momentsLogPath = () => path.join(DATA_DIR, MOMENTS_LOG);
let momentsLogCount = 0;

function replayMomentsLog() {
  let added = 0;
  try {
    const raw = fs.readFileSync(momentsLogPath(), 'utf8');
    const known = new Set((db.moments || []).map((m) => m.id));
    raw.split('\n').forEach((line) => {
      const t = line.trim();
      if (!t) return;
      try {
        const m = JSON.parse(t);
        if (m && m.id && !known.has(m.id)) { db.moments.unshift(m); known.add(m.id); added++; }
      } catch (err) { /* 跳过坏行 */ }
    });
  } catch (err) { /* 没有日志文件就是第一次跑 */ }
  if (added) {
    try {
      writeJson(path.join(DATA_DIR, 'moments.json'), { moments: db.moments });
      fs.writeFileSync(momentsLogPath(), '', 'utf8');
    } catch (err) { /* 合并失败也不影响使用，下次再合 */ }
  }
  return added;
}

/** 发一条新动态：只追加一行 + 放进内存 */
function appendMoment(moment) {
  try {
    fs.appendFileSync(momentsLogPath(), JSON.stringify(moment) + '\n', 'utf8');
    momentsLogCount++;
  } catch (err) { /* 写不进日志就让下次整体保存兜底 */ }
  db.moments.unshift(moment);
}

/* --------------------------------------------------- 转账单（待收款 / 24 小时退回）
   付款时先扣付款方余额，钱挂在转账单上；对方点「收钱」才进对方余额，
   超过 24 小时没人收，自动原路退回到付款方余额。 */
const TRANSFER_TTL_MS = 24 * 60 * 60 * 1000;

/* ============================================================
   钱的地基（以后接了真钱，靠这三样保证不出错）

   ① 余额只有一个入口：applyMoney()。它负责四舍五入到分、
      不允许把余额扣成负数、并把每一笔写进总账（谁/多少/为什么/改完剩多少）。
   ② 幂等：客户端每笔钱都带 requestId，超时重发 / 连点只会真正处理一次。
      走到一半崩了也不会重复扣 —— 第二次来会看到「处理中」，让它去查余额。
   ③ 开机自检：总账里每个账号最后那笔的余额，必须和 users.json 里的余额一致；
      不一致就大声报警（并留一份现场），绝不悄悄继续跑。
   ============================================================ */

const MONEY_JOURNAL = 'money-journal.jsonl';
const MONEY_STATE = 'money-state.json';
const IDEM_FILE = 'idem.json';

/** 统一四舍五入到「分」：钱一律走这个，别各处自己 Math.round */
function moneyRound(v) {
  const n = Number(v);
  if (!isFinite(n)) return NaN;
  return Math.round(n * 100) / 100;
}

/** 支付规则可以在后台/文件里调（data/payrules.json），不用改代码、不用出包。
    例：{ "redPacketMax": 200 } —— 想和微信一致就把红包上限压到 200。 */
function payRuleNum(key, def) {
  try {
    const cfg = readJson(path.join(DATA_DIR, 'payrules.json'), {});
    const v = Number(cfg && cfg[key]);
    if (isFinite(v) && v > 0) return v;
  } catch (err) { /* 读不到就用默认 */ }
  return def;
}

/** 总账：追加一行（崩溃也不影响已写入的历史） */
function journalMoney(row) {
  try {
    fs.appendFileSync(path.join(DATA_DIR, MONEY_JOURNAL), JSON.stringify(row) + '\n', 'utf8');
  } catch (err) { /* 总账写不进去不能拦住交易，但下面那份 state 还会写 */ }
  try {
    const st = readJson(path.join(DATA_DIR, MONEY_STATE), { users: {} });
    if (!st.users) st.users = {};
    st.users[row.userId] = { balance: row.after, at: row.at };
    writeJson(path.join(DATA_DIR, MONEY_STATE), st);
  } catch (err) { /* 自检用的快照，写不了下次再写 */ }
}

/**
 * 唯一允许改余额的地方。
 * @param user   要改的账号对象
 * @param delta  变动（正=进钱，负=出钱）
 * @param meta   { reason, ref, allowNegative }
 * @returns      { balance } 成功；{ error } 失败（余额不够 / 金额不合法）
 */
function applyMoney(user, delta, meta) {
  if (!user || !user.id) return { error: '账号不存在' };
  const d = moneyRound(delta);
  if (!isFinite(d)) return { error: '金额不合法' };
  const before = moneyRound(user.balance) || 0;
  const after = moneyRound(before + d);
  if (!isFinite(after)) return { error: '金额不合法' };
  const allowNeg = !!(meta && meta.allowNegative);
  /* 余额扣成负数 = 线上事故：默认一律拒绝（管理员改账除外） */
  if (!allowNeg && after < 0) {
    return { error: '余额不足（当前 ¥' + before.toFixed(2) + '，需要 ¥' + Math.abs(d).toFixed(2) + '）' };
  }
  if (d === 0) return { balance: before, before: before, delta: 0 };
  user.balance = after;
  journalMoney({
    at: new Date().toISOString(), userId: user.id, delta: d,
    before: before, after: after,
    reason: (meta && meta.reason) || '', ref: (meta && meta.ref) || ''
  });
  return { balance: after, before: before, delta: d };
}

/* ---------------- ② 幂等 ---------------- */
let idemStore = readJson(path.join(DATA_DIR, IDEM_FILE), { items: {} });
if (!idemStore.items) idemStore.items = {};
const IDEM_MAX = 3000;

function idemBegin(user, body, tag) {
  const raw = String((body && body.requestId) || '').trim().slice(0, 64);
  if (!raw || !user || !user.id) return { key: '' };   // 老客户端没带：不拦、也不缓存
  const key = user.id + ':' + tag + ':' + raw;
  const hit = idemStore.items[key];
  if (hit) {
    /* payload=null 表示「上一笔还没落定」（正在处理 / 处理到一半崩了）：
       这时候绝不能再扣一次，让客户端去查余额 */
    if (!hit.payload) return { key: key, dup: true, inflight: true, cached: null };
    return { key: key, dup: true, inflight: false, cached: hit.payload };
  }
  idemStore.items[key] = { at: Date.now(), payload: null };
  idemPrune();
  idemSave();
  return { key: key, dup: false };
}

function idemFinish(key, payload) {
  if (!key) return;
  idemStore.items[key] = { at: Date.now(), payload: payload || {} };
  idemPrune();
  idemSave();
}

function idemPrune() {
  const keys = Object.keys(idemStore.items);
  if (keys.length <= IDEM_MAX) return;
  keys.sort((a, b) => (idemStore.items[a].at || 0) - (idemStore.items[b].at || 0));
  keys.slice(0, keys.length - IDEM_MAX).forEach((k) => delete idemStore.items[k]);
}

function idemSave() {
  try { writeJson(path.join(DATA_DIR, IDEM_FILE), idemStore); } catch (err) { /* 写不了就算了，内存里还在 */ }
}

/* ---------------- ③ 开机自检 ---------------- */
/** 总账快照 vs 实际余额：不一致就报警（不自动改，先留现场） */
function moneySelfCheck() {
  let bad = 0;
  try {
    const st = readJson(path.join(DATA_DIR, MONEY_STATE), { users: {} });
    const users = (st && st.users) || {};
    db.users.forEach((u) => {
      const rec = users[u.id];
      if (!rec) return;                       // 这个账号没有总账记录（新账号 / 老数据），跳过
      const now = moneyRound(u.balance) || 0;
      if (Math.abs(now - (Number(rec.balance) || 0)) > 0.005) {
        bad += 1;
        console.log('[钱的自检] 余额和总账对不上：' + (u.nickname || u.username || u.id)
          + ' 账上 ' + now.toFixed(2) + ' / 总账 ' + (Number(rec.balance) || 0).toFixed(2));
      }
      /* 开了经营账户的，经营账户那份也要对得上 */
      const brec = users['biz:' + u.id];
      if (brec) {
        const bizBal = moneyRound(bizOf(u.id, false).balance) || 0;
        if (Math.abs(bizBal - (Number(brec.balance) || 0)) > 0.005) {
          bad += 1;
          console.log('[钱的自检] 经营账户和总账对不上：' + (u.nickname || u.username || u.id)
            + ' 账上 ' + bizBal.toFixed(2) + ' / 总账 ' + (Number(brec.balance) || 0).toFixed(2));
        }
      }
    });
  } catch (err) {
    console.log('[钱的自检] 没跑成：' + err.message);
  }
  if (bad) console.log('[钱的自检] 一共 ' + bad + ' 个账号对不上 —— 接真钱之前必须先查清');
  else console.log('[钱的自检] 余额和总账一致');
  return bad;
}

function transferSnapshot(t) {
  return JSON.stringify({
    id: t.id,
    amount: t.amount,
    note: t.note || '',
    status: t.status,                 // pending / received / refunded
    method: t.method || 'balance',
    fromId: t.fromId,
    toId: t.toId,
    createdAt: t.createdAt,
    expiresAt: t.expiresAt,
    receivedAt: t.receivedAt || '',
    refundedAt: t.refundedAt || '',
    refundedBy: t.refundedBy || ''      // 收款方自己退还的，还是 24 小时自动退回
  });
}

/** 把会话里那条转账消息的内容刷成最新状态（客户端按它画卡片） */
function syncTransferMessage(t) {
  const chat = db.chats.find((c) => c.id === t.chatId);
  if (!chat) return null;
  const messages = loadMessages(chat.id);
  const msg = messages.find((m) => m.id === t.messageId);
  if (!msg) return null;
      msg.content = transferSnapshot(t);
      try {
        saveMessagesFile(chat.id, messages);
      } catch (err) { /* 忽略 */ }
  return msg;
}

function broadcastTransfer(t, kind) {
  syncTransferMessage(t);
  const payload = {
    type: 'transfer',
    event: kind || 'update',
    chatId: t.chatId,
    messageId: t.messageId,
    transfer: JSON.parse(transferSnapshot(t))
  };
  [t.fromId, t.toId].forEach((id) => { if (id) sendTo(id, payload); });
}

/** 24 小时没被收款的，自动退回给付款方 */
function expireTransfers() {
  const t = Date.now();
  let changed = 0;
  db.transfers.forEach((tr) => {
    if (tr.status !== 'pending') return;
    if (!(tr.expiresAt && tr.expiresAt <= t)) return;
    const from = findUser(tr.fromId);
    if (from) {
      /* 24 小时没人收款：原路退回，走统一入口（记总账 + 不会算错分） */
      applyMoney(from, Number(tr.amount) || 0, { reason: '转账 24 小时未收自动退回', ref: tr.id });
      sendTo(from.id, { type: 'balance', balance: from.balance });
    }
    tr.status = 'refunded';
    tr.refundedAt = now();
    changed++;
    broadcastTransfer(tr, 'refunded');
  });
  if (changed) saveUsers();
  if (changed) saveTransfers();
  return changed;
}

/* 按卡号认银行（微信就是输入卡号自动跳银行）：只认最常见的几个前缀 */
/** 绑卡时能选的银行（名字 + 品牌色，App 里画成带颜色的小方块） */
const BANK_LIST = [
  { name: '工商银行', color: '#C8161D', short: '工' },
  { name: '建设银行', color: '#0B4DA2', short: '建' },
  { name: '农业银行', color: '#0E8B4A', short: '农' },
  { name: '中国银行', color: '#B01F24', short: '中' },
  { name: '招商银行', color: '#C7000B', short: '招' },
  { name: '交通银行', color: '#1B4E9B', short: '交' },
  { name: '邮储银行', color: '#0E7B40', short: '邮' },
  { name: '中信银行', color: '#D0202F', short: '信' },
  { name: '民生银行', color: '#0E5EA8', short: '民' },
  { name: '浦发银行', color: '#0A4C8B', short: '浦' },
  { name: '兴业银行', color: '#1F4C9C', short: '兴' },
  { name: '光大银行', color: '#8B1A2B', short: '光' },
  { name: '平安银行', color: '#F36F21', short: '平' },
  { name: '广发银行', color: '#C8102E', short: '广' },
  { name: '华夏银行', color: '#0E5EA8', short: '华' },
  { name: '北京银行', color: '#0B4DA2', short: '京' },
  { name: '上海银行', color: '#0E5EA8', short: '沪' },
  { name: '宁波银行', color: '#1B4E9B', short: '宁' },
  { name: '江苏银行', color: '#0E7B40', short: '苏' },
  { name: '微众银行', color: '#0E9C6B', short: '微' },
  { name: '网商银行', color: '#1F7BE0', short: '网' },
  { name: '其他银行', color: '#8A8A8E', short: '其' }
];

const BANK_BY_PREFIX = [
  { p: ['622575', '622576', '622588', '621286'], name: '招商银行' },
  { p: ['622202', '622203', '621226', '9558'], name: '工商银行' },
  { p: ['4367', '6227', '6217'], name: '建设银行' },
  { p: ['622848', '622845', '9559'], name: '农业银行' },
  { p: ['621661', '601382', '456351'], name: '中国银行' },
  { p: ['622260', '622262', '601428'], name: '交通银行' },
  { p: ['622188', '621096', '9551'], name: '邮储银行' },
  { p: ['622690', '622691'], name: '中信银行' },
  { p: ['622155', '622156'], name: '平安银行' },
  { p: ['622568', '622569'], name: '广发银行' },
  { p: ['622908', '622909'], name: '兴业银行' },
  { p: ['622622', '622617'], name: '民生银行' },
  { p: ['622636', '622637'], name: '华夏银行' },
  { p: ['622588', '622589'], name: '光大银行' }
];
function guessBankByCardNo(number) {
  const n = String(number || '').replace(/\D/g, '');
  for (const row of BANK_BY_PREFIX) {
    for (const p of row.p) {
      if (n.indexOf(p) === 0) return { name: row.name, hit: p };
    }
  }
  return { name: '', hit: '' };
}

/** 这张尾号的卡上还有没有在处理中的提现 */
function pendingWithdrawToTail(user, tail) {
  try {
    return readWalletOps().ops.some((o) =>
      o.userId === user.id && o.kind === 'withdraw' && o.status === 'pending' &&
      String(o.bankText || '').indexOf(String(tail)) >= 0);
  } catch (e) { return false; }
}

/* --------------------------------------------------- 青少年模式（微信：设置 → 青少年模式）
   开关要密码（4 位），开了以后按勾选把某些功能关掉：视频号 / 直播 / 游戏 / 附近 / 摇一摇 / 搜一搜 / 支付。
   密码只存哈希；家长手机号只存脱敏。 */
const TEEN_PATHS = [
  { p: 'feed', k: 'feed', name: '视频号' },
  { p: 'live', k: 'live', name: '直播' },
  { p: 'games', k: 'games', name: '游戏' },
  { p: 'nearby', k: 'nearby', name: '附近' },
  { p: 'shake', k: 'shake', name: '摇一摇' },
  { p: 'bottle', k: 'bottle', name: '漂流瓶' },
  { p: 'search', k: 'search', name: '搜一搜' },
  /* 2026-10-13 扩成微信那一整套：能单独开关的项目多了这些 */
  { p: 'music', k: 'music', name: '听一听' },
  { p: 'miniapps', k: 'miniapps', name: '小程序' },
  { p: 'shop', k: 'shop', name: '小店与卡包' },
  { p: 'mall', k: 'shop', name: '商城' },
  { p: 'moments', k: 'moments', name: '朋友圈' },
  { p: 'oa', k: 'oa', name: '公众号' },
  { p: 'scan', k: 'scan', name: '扫一扫' },
  { p: 'pay', k: 'pay', name: '支付' },
  { p: 'transfers', k: 'pay', name: '转账' },
  { p: 'redpacket', k: 'pay', name: '红包' },
  { p: 'redpackets', k: 'pay', name: '红包' },
  { p: 'gifts', k: 'pay', name: '礼物' },
  { p: 'bills', k: 'pay', name: '零钱账单' },
  { p: 'wallet', k: 'pay', name: '钱包' }
];
/* 默认就是微信那套「仅聊天」：视频号/直播/游戏/附近/摇一摇/漂流瓶/搜一搜/听一听/
   小程序/购物/朋友圈 全关；公众号和扫一扫留着（加好友、看通知要用）；支付默认关。 */
const DEFAULT_TEEN_SCOPES = {
  feed: 0, live: 0, games: 0, nearby: 0, shake: 0, bottle: 0, search: 0,
  music: 0, miniapps: 0, shop: 0, moments: 0,
  oa: 1, scan: 1, pay: 0
};
/* 使用时长 / 宵禁 / 单日支付上限（微信青少年模式的「时间管理」+ 支付限额） */
const DEFAULT_TEEN_LIMITS = {
  dailyMinutes: 40,        // 每天能用多少分钟；0 = 不限
  /* 宵禁默认**关**：老版本 App 还没有这一页的设置入口，默认开着会在晚上
     把已经开了未成年人模式的账号突然锁住（界面又找不到开关）。
     新版本装上去之后，家长在页面里打开就行。 */
  curfewOn: 0,
  curfewStart: '22:00',
  curfewEnd: '06:00',
  payLimit: 0              // 单日能花多少钱（元）；0 = 一分都不能花；-1 = 不限
};

/** 今天的日期串（按北京时间），用来做「每天重算」的键 */
function todayKey() {
  const d = new Date(Date.now() + 8 * 3600 * 1000);
  return d.toISOString().slice(0, 10);
}

/** 取（必要时重置）今天的用量：minutes = 已用分钟，pay = 已花金额 */
function teenUsageOf(user) {
  const t = (user && user.teen) || {};
  const key = todayKey();
  const u = t.usage && t.usage.date === key ? t.usage : { date: key, minutes: 0, pay: 0 };
  return { minutes: Math.max(0, Number(u.minutes) || 0), pay: Math.max(0, Number(u.pay) || 0), date: key };
}

/** 把「现在到点的分钟数」写成 HH:mm → 分钟；写错就返回 null */
function hhmm(v) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(v || '').trim());
  if (!m) return null;
  const h = Number(m[1]), mi = Number(m[2]);
  if (h > 23 || mi > 59) return null;
  return h * 60 + mi;
}

/** 现在是不是在宵禁时段里（跨零点的那段也认） */
function inCurfew(limits) {
  if (!limits || !limits.curfewOn) return false;
  const a = hhmm(limits.curfewStart), b = hhmm(limits.curfewEnd);
  if (a === null || b === null || a === b) return false;
  const d = new Date(Date.now() + 8 * 3600 * 1000);
  const nowM = d.getUTCHours() * 60 + d.getUTCMinutes();
  return a < b ? (nowM >= a && nowM < b) : (nowM >= a || nowM < b);   // a>b = 跨零点
}

function teenCfg(user) {
  const t = (user && user.teen) || {};
  const limits = Object.assign({}, DEFAULT_TEEN_LIMITS, t.limits || {});
  const usage = teenUsageOf(user);
  const unlockedUntil = Number(t.unlockUntil) || 0;
  const unlocked = unlockedUntil > Date.now();
  /* 锁住的两种原因：今天时间用完 / 正在宵禁。临时解锁（监护人输密码）期间不算锁。 */
  let locked = false, lockReason = '';
  if (t.enabled && !unlocked) {
    if (limits.dailyMinutes > 0 && usage.minutes >= limits.dailyMinutes) {
      locked = true; lockReason = '今天的 ' + limits.dailyMinutes + ' 分钟已经用完了';
    } else if (inCurfew(limits)) {
      locked = true; lockReason = '现在是宵禁时间（' + limits.curfewStart + ' - ' + limits.curfewEnd + '）';
    }
  }
  return {
    enabled: !!t.enabled,
    hasPin: !!(t.salt && t.hash),
    scopes: Object.assign({}, DEFAULT_TEEN_SCOPES, t.scopes || {}),
    guardianPhone: t.guardianPhoneMask || '',
    setAt: t.setAt || '',
    limits: limits,
    usage: usage,
    left: limits.dailyMinutes > 0 ? Math.max(0, limits.dailyMinutes - usage.minutes) : -1,
    locked: locked,
    lockReason: lockReason,
    unlockUntil: unlocked ? unlockedUntil : 0
  };
}
/** 未成年人模式下这个接口能不能用（不能用就返回一句人话） */
function teenBlocked(user, parts, method) {
  const cfg = teenCfg(user);
  if (!cfg.enabled) return '';
  /* 时间用完 / 宵禁：发消息和花钱这两类直接挡住（界面那边也会整页锁住）。
     只挡这两类，不然连会话列表都刷不出来，会显得像"App 坏了"。 */
  if (cfg.locked) {
    const isSend = (parts[0] === 'chats' && parts[2] === 'messages' && method === 'POST');
    const isPay = ['transfers', 'redpacket', 'redpackets', 'pay', 'gifts'].indexOf(parts[0]) >= 0;
    if (isSend || isPay) {
      return '未成年人模式：' + cfg.lockReason + '，需要监护人输入独立密码解锁';
    }
  }
  /* 单日支付额度：到顶了就不让花钱了（-1 = 不限） */
  if (cfg.limits.payLimit >= 0 && cfg.usage.pay >= cfg.limits.payLimit) {
    const isPay2 = ['transfers', 'redpacket', 'redpackets', 'pay', 'gifts'].indexOf(parts[0]) >= 0;
    if (isPay2) {
      return cfg.limits.payLimit > 0
        ? ('未成年人模式：今天的支付额度（' + cfg.limits.payLimit + ' 元）已经用完')
        : '未成年人模式：支付已被家长关闭';
    }
  }
  const hit = TEEN_PATHS.find((x) => x.p === parts[0] && !cfg.scopes[x.k]);
  return hit ? ('未成年人模式下「' + hit.name + '」已按家长设置限制，需要独立密码才能使用') : '';
}

/* --------------------------------------------------- 关键词自动回复（微信后台那套「自动回复」）
   后台配规则：用户发的话里命中关键词 → 直接用你配的文案回（比 AI 更准、可控）；
   没命中才轮到 AI 按知识库答。规则可设「包含/完全相同」、可分单聊/群聊、可单独关。
   默认关（enabled: 0），配了规则并在后台打开才生效。 */
const AUTOREPLY_FILE = 'autoreply.json';
let autoReplyCache = null;
const DEFAULT_AUTOREPLY = {
  enabled: 0,                  // 总开关（后台「自动回复」页里打开）
  scope: 'kefu',               // kefu = 只对客服会话生效 / all = 所有机器人会话
  fallback: '',                // 都没命中时补一句（留空就不补，交给 AI）
  rules: []                    // [{ id, keyword, match:'contains'|'exact', reply, enabled }]
};
function readAutoReply() {
  if (autoReplyCache) return autoReplyCache;
  let raw = null;
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, AUTOREPLY_FILE), 'utf8')); } catch (e) { raw = null; }
  const cfg = Object.assign({}, DEFAULT_AUTOREPLY, raw && typeof raw === 'object' ? raw : {});
  if (!Array.isArray(cfg.rules)) cfg.rules = [];
  autoReplyCache = cfg;
  return cfg;
}
function saveAutoReply(next) {
  autoReplyCache = Object.assign({}, DEFAULT_AUTOREPLY, next || {});
  try { writeJson(path.join(DATA_DIR, AUTOREPLY_FILE), autoReplyCache); } catch (e) { }
  return autoReplyCache;
}
/** 命中第一条规则就返回它的回复文案（没有就返回空串） */
function autoReplyHit(text) {
  const cfg = readAutoReply();
  if (!cfg.enabled) return '';
  const t = String(text || '').trim();
  if (!t) return '';
  for (const r of cfg.rules) {
    if (r && r.enabled !== false && r.keyword && r.reply) {
      const k = String(r.keyword).trim();
      if (!k) continue;
      if (r.match === 'exact' ? (t === k) : (t.indexOf(k) >= 0)) return String(r.reply);
    }
  }
  return '';
}

/* --------------------------------------------------- 支付分（微信那套）
   区间 350~950，初始 650；三个维度算分：身份特质 / 支付行为 / 履约记录；
   分数够就能用「免押服务」（后台可配：名字、门槛分、说明）；
   页面上能看到分是怎么来的、最近的变化记录。 */
const PAYSCORE_FILE = 'payscore.json';
let payScoreCache = null;
const DEFAULT_PAYSCORE = {
  enabled: 1,
  min: 350,
  max: 950,
  base: 650,
  levels: [
    { v: 800, name: '极好' },
    { v: 700, name: '优秀' },
    { v: 600, name: '良好' },
    { v: 500, name: '一般' },
    { v: 0, name: '较差' }
  ],
  services: [
    { id: 'ps1', name: '共享充电宝免押', need: 600, desc: '扫码即借，不用押金', enabled: true },
    { id: 'ps2', name: '骑车免押金', need: 600, desc: '先骑后付', enabled: true },
    { id: 'ps3', name: '酒店免押入住', need: 700, desc: '先住后付、离店结算', enabled: true },
    { id: 'ps4', name: '打车先乘后付', need: 700, desc: '到达后再付款', enabled: true }
  ],
  note: '支付分由身份特质、支付行为、履约记录三部分综合评估，每月 1 号更新一次，多使用、按时付款都会加分。'
};

function readPayScore() {
  if (payScoreCache) return payScoreCache;
  let raw = null;
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, PAYSCORE_FILE), 'utf8')); } catch (e) { raw = null; }
  const cfg = Object.assign({}, DEFAULT_PAYSCORE, raw && typeof raw === 'object' ? raw : {});
  if (!Array.isArray(cfg.services) || !cfg.services.length) cfg.services = DEFAULT_PAYSCORE.services;
  if (!Array.isArray(cfg.levels) || !cfg.levels.length) cfg.levels = DEFAULT_PAYSCORE.levels;
  payScoreCache = cfg;
  return cfg;
}
function savePayScore(next) {
  payScoreCache = Object.assign({}, DEFAULT_PAYSCORE, next || {});
  try { writeJson(path.join(DATA_DIR, PAYSCORE_FILE), payScoreCache); } catch (e) { }
  return payScoreCache;
}

/** 算分：三个维度各 0~100，加权后映射到 350~950 */
function payScoreOf(user) {
  const cfg = readPayScore();
  const real = !!(user.realName && user.idCardHash);
  const banks = Array.isArray(user.bankCards) ? user.bankCards.length : 0;
  const phone = !!user.phone;
  const ageDays = user.createdAt ? Math.max(0, (Date.now() - new Date(user.createdAt).getTime()) / 86400000) : 0;

  const identity = Math.min(100,
    (real ? 45 : 0) + (banks > 0 ? 30 : 0) + (phone ? 15 : 0) + Math.min(10, Math.round(ageDays / 3)));

  const trs = (db.transfers || []).filter((t) => t.fromId === user.id || t.toId === user.id);
  const rps = (db.redpackets || []).filter((r) => r.fromId === user.id ||
    (Array.isArray(r.claims) ? r.claims.some((c) => c.userId === user.id) : false));
  const behavior = Math.min(100, Math.min(55, trs.length * 4) + Math.min(45, rps.length * 3));

  let vio = 0;
  try { vio = (opsStore.violations || []).filter((v) => v.userId === user.id).length; } catch (e) { vio = 0; }
  const perform = Math.max(0, 100 - vio * 25);

  const total = identity * 0.3 + behavior * 0.4 + perform * 0.3;
  let score = Math.round(cfg.base - 60 + total * 1.3);
  score = Math.max(cfg.min, Math.min(cfg.max, score));

  const level = (cfg.levels || []).find((l) => score >= Number(l.v)) || { name: '良好' };
  const services = (cfg.services || []).filter((s) => s.enabled !== false).map((s) => ({
    id: s.id, name: s.name, desc: s.desc || '', need: Number(s.need) || 0,
    ok: score >= (Number(s.need) || 0), gap: Math.max(0, (Number(s.need) || 0) - score)
  }));

  /* 分值变化：直接用真实事件拼出来（不额外记账，重启不丢） */
  const history = [];
  if (real) history.push({ at: user.idCardVerifiedAt || user.createdAt || '', text: '完成实名认证', delta: +40 });
  if (banks > 0) history.push({ at: (user.bankCards[banks - 1] || {}).addedAt || '', text: '绑定银行卡', delta: +25 });
  trs.slice(-6).forEach((t) => history.push({
    at: t.createdAt, text: t.fromId === user.id ? '发起转账' : '收到转账', delta: t.fromId === user.id ? +3 : +5
  }));
  rps.slice(-6).forEach((r) => history.push({
    at: r.createdAt, text: r.fromId === user.id ? '发出红包' : '收到红包', delta: r.fromId === user.id ? +2 : +3
  }));
  if (vio > 0) history.push({ at: now(), text: '有违规记录被扣分', delta: -25 * vio });
  history.sort((a, b) => String(b.at).localeCompare(String(a.at)));

  return {
    score,
    level: level.name,
    min: cfg.min,
    max: cfg.max,
    dims: [
      { key: 'identity', name: '身份特质', value: identity, desc: real ? '已实名' : '还没实名认证', tip: '完成实名认证 + 绑定银行卡能快速加分' },
      { key: 'behavior', name: '支付行为', value: behavior, desc: '转账 ' + trs.length + ' 笔 · 红包 ' + rps.length + ' 次', tip: '多用转账、红包、收付款，保持活跃' },
      { key: 'perform', name: '履约记录', value: perform, desc: vio > 0 ? ('有 ' + vio + ' 次违规') : '没有异常记录', tip: '按时收款、不要发违规内容' }
    ],
    services,
    history: history.slice(0, 12),
    note: cfg.note || DEFAULT_PAYSCORE.note
  };
}

/* --------------------------------------------------- 经营账户（微信「经营账户」那套）
   · 收款记录：谁在什么时候付了多少钱（转账收款 / 红包收款 / 充值都算经营收款）
   · 经营设置：到账方式（零钱 / 经营账户）、收款提醒、自动提现到零钱、结算周期、店铺名
   · 提现到零钱：经营账户里的钱随时提到零钱（留一条提现流水）
   · 开票信息：抬头、税号、地址电话、开户行账号；可以按金额申请开票，后台能处理
   默认「到账方式 = 零钱」，和以前完全一样；只有店主自己开了经营账户才会走经营账户余额。 */
const BIZ_FILE = 'biz.json';
let bizCache = null;
const DEFAULT_BIZ = {
  enabled: false,
  balance: 0,
  createdAt: '',
  settings: {
    arrival: 'balance',      // balance 零钱 / biz 经营账户
    notify: true,            // 收款提醒
    autoWithdraw: false,     // 自动提现到零钱
    settle: 'T+1',           // 结算周期（展示用）
    feeRate: 0.006,          // 手续费率（展示用，0.6%）
    shopName: '',
    remark: ''
  },
  invoice: { title: '', taxNo: '', address: '', phone: '', bankName: '', bankAccount: '' },
  records: [],               // 收款 / 提现 / 开票申请 流水（一条一行那种）
  invoices: []
};

function readBizAll() {
  if (bizCache) return bizCache;
  let raw = null;
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, BIZ_FILE), 'utf8')); } catch (e) { raw = null; }
  bizCache = (raw && typeof raw === 'object' && raw.accounts && typeof raw.accounts === 'object') ? raw : { accounts: {} };
  return bizCache;
}
function saveBizAll() { try { writeJson(path.join(DATA_DIR, BIZ_FILE), bizCache); } catch (e) { } }

/** 取某个人的经营账户（没有就按默认值建一个，但不落盘，等真的改了才存） */
function bizOf(userId, create) {
  const all = readBizAll();
  let acc = all.accounts[userId];
  if (!acc && create) {
    acc = JSON.parse(JSON.stringify(DEFAULT_BIZ));
    acc.createdAt = now();
    all.accounts[userId] = acc;
    saveBizAll();
  }
  if (!acc) return JSON.parse(JSON.stringify(DEFAULT_BIZ));
  acc.settings = Object.assign({}, DEFAULT_BIZ.settings, acc.settings || {});
  acc.invoice = Object.assign({}, DEFAULT_BIZ.invoice, acc.invoice || {});
  if (!Array.isArray(acc.records)) acc.records = [];
  if (!Array.isArray(acc.invoices)) acc.invoices = [];
  acc.balance = Math.round((Number(acc.balance) || 0) * 100) / 100;
  return acc;
}

/** 记一笔经营流水（收款 / 提现 / 开票） */
function bizPush(userId, row) {
  const acc = bizOf(userId, true);
  acc.records.unshift(Object.assign({
    id: uid('bz'), orderNo: uid('O'), status: 'done', createdAt: now()
  }, row));
  if (acc.records.length > 2000) acc.records.length = 2000;
  saveBizAll();
  return acc.records[0];
}

/** 收到钱：如果这个人开了经营账户且到账方式选的是经营账户，钱进经营账户余额；否则照旧进零钱。
    两种情况都会记一条收款流水（后台查账看的就是它）。 */
/* ============================================================
   收付款（微信那套）
   付款码池：code -> { userId, exp, used }
   · 18 位数字，和微信一样；60 秒一换；用过（付过一笔）立刻作废
   · 同一秒内重复请求（客户端刷新、网络重试）拿到的还是同一个码，
     不然商家那边刚扫到就过期了
   ============================================================ */
const PAY_CODE_TTL_MS = 60 * 1000;
const payCodes = new Map();

function newPayCode(userId) {
  const t = Date.now();
  payCodes.forEach((v, k) => { if (v.exp <= t) payCodes.delete(k); });
  let exist = '';
  payCodes.forEach((v, k) => {
    if (!exist && v.userId === userId && v.exp > t && !v.used) exist = k;
  });
  if (exist) return exist;
  let code = '1';
  while (code.length < 18) code += String(Math.floor(Math.random() * 10));
  while (payCodes.has(code)) code = '1' + String(Math.floor(Math.random() * 1e17)).padStart(17, '0');
  payCodes.set(code, { userId: userId, exp: t + PAY_CODE_TTL_MS, used: false });
  if (payCodes.size > 5000) payCodes.delete(payCodes.keys().next().value);
  return code;
}

/** 收付款码里的链接基地：优先用请求本身的域名（手机连内网也能扫） */
function payBaseUrl(req) {
  const host = String((req && req.headers && req.headers.host) || '').split(',')[0].trim();
  if (host && /^[0-9A-Za-z.\-]+(:\d+)?$/.test(host)) return 'https://' + host;
  return 'https://' + (process.env.PUBLIC_HOST || 'aa.x8iu.com');
}

/** 「设置金额」那张收款码的金额签名：改一个数字就验不过 */
function payAmountSig(userCd, amountText, exp) {
  return crypto.createHmac('sha256', db.secret)
    .update('payamt:' + userCd + '|' + amountText + '|' + exp)
    .digest('base64url').slice(0, 16);
}

/** 扫到的字符串 → { kind: 'pay' | 'receive', target, amount, code } 或 { error } */
function resolvePayText(raw) {
  const t = String(raw || '').trim();
  if (!t) return { error: '没扫到内容' };
  /* 18 位纯数字 = 付款码（别人扫我，商家扫我） */
  if (/^\d{18}$/.test(t)) {
    const rec = payCodes.get(t);
    if (!rec || rec.used || rec.exp <= Date.now()) return { error: '这个付款码已经过期了，让对方点一下刷新' };
    const u = findUser(rec.userId);
    if (!u) return { error: '付款码的主人找不到了' };
    return { kind: 'pay', target: u, code: t, amount: 0 };
  }
  if (t.indexOf('pay.html') < 0) return { error: '这不是收付款码' };
  /* 付款码的二维码：pay.html?c=18位数字 */
  const mc = /[?&]c=(\d{6,24})/.exec(t);
  if (mc) return resolvePayText(mc[1]);
  /* 收款码：pay.html?u=个人码[&a=金额&e=过期时间&s=签名] */
  const mu = /[?&]u=([A-Za-z0-9._-]{4,80})/.exec(t);
  if (!mu) return { error: '这不是收付款码' };
  const target = findUserByName(usernameFromUserCode(mu[1]));
  if (!target) return { error: '这个收款码无效' };
  let amount = 0;
  const ma = /[?&]a=(\d+(?:\.\d{1,2})?)/.exec(t);
  const me = /[?&]e=(\d{10,16})/.exec(t);
  const ms = /[?&]s=([A-Za-z0-9_-]{8,64})/.exec(t);
  if (ma && me && ms) {
    if (Number(me[1]) < Date.now()) return { error: '这个收款码已经过期了' };
    if (payAmountSig(mu[1], ma[1], me[1]) !== ms[1]) return { error: '这个收款码的金额被改过，让对方重新生成一张' };
    amount = rpRound2(Number(ma[1]) || 0);
  }
  return { kind: 'receive', target: target, amount: amount };
}

/* 扫码付款限流：每人 1 分钟最多付 20 笔（防脚本连着刷） */
const payHits = new Map();
function payRateAllow(userId) {
  const t = Date.now();
  let r = payHits.get(userId);
  if (!r || t - r.t > 60000) { r = { t: t, n: 0 }; payHits.set(userId, r); }
  r.n += 1;
  if (payHits.size > 5000) payHits.clear();
  return r.n <= 20;
}

function bizCollect(user, amount, fromName, fromId, kind, note, reason) {
  const acc = bizOf(user.id, false);
  const toBiz = !!(acc.enabled && acc.settings.arrival === 'biz');
  if (toBiz) {
    const a = bizOf(user.id, true);
    const beforeBiz = moneyRound(a.balance);
    a.balance = moneyRound(beforeBiz + amount);
    saveBizAll();
    /* 经营账户也是钱：同样进总账（userId 用 biz: 前缀，和零钱分开对） */
    journalMoney({
      at: new Date().toISOString(), userId: 'biz:' + user.id,
      delta: moneyRound(amount), before: beforeBiz, after: a.balance,
      reason: (kind === 'redpacket' ? '抢红包' : (kind === 'transfer' ? '收转账' : '收款')) + '（经营账户）',
      ref: fromId || ''
    });
  } else {
    /* 钱一律走 applyMoney：统一四舍五入到分 + 记总账（接真钱靠这本账对） */
    applyMoney(user, amount, {
      reason: reason || (kind === 'redpacket' ? '抢红包' : (kind === 'transfer' ? '收转账' : '收款')),
      ref: fromId || ''
    });
    saveUsers();
  }
  bizPush(user.id, {
    kind: 'collect', amount, fromName: fromName || '', fromId: fromId || '',
    method: kind || 'transfer', note: note || '', settled: !toBiz
  });
  sendTo(user.id, { type: 'balance', balance: Number(user.balance) || 0 });
  return toBiz;
}

/* --------------------------------------------------- 账户升级服务（微信支付那套）
   微信的逻辑：账户分三档，等级越高，收付款额度越大——
   · 0 档「未完善身份信息」：只实名了没有，单笔/单日只能 1000
   · 1 档「已实名」：填了身份证，5000
   · 2 档「已升级」：实名 + 绑了银行卡，20000
   升级动作本身不收费，就是「把该填的填完」；额度按实际完成情况算，不是随便点一下就能变。
   转账 / 发红包 / 提现都要过这个额度检查（和微信一样：超了就提示去升级）。 */
const WALLET_LEVELS = [
  { level: 0, name: '未完善身份信息', tip: '实名认证后额度提升到 5000 元', single: 1000, day: 1000, receive: 1000 },
  { level: 1, name: '已实名', tip: '绑定银行卡后额度提升到 20000 元', single: 5000, day: 5000, receive: 5000 },
  { level: 2, name: '已升级（实名 + 绑卡）', tip: '已经是最高等级', single: 20000, day: 20000, receive: 20000 }
];

function walletLevelOf(user) {
  const real = !!(user.realName && user.idCardHash);
  const bank = (Array.isArray(user.bankCards) ? user.bankCards.length : 0) > 0;
  if (real && bank) return 2;
  if (real) return 1;
  return 0;
}
function walletLevelInfo(user) {
  const lv = walletLevelOf(user);
  return WALLET_LEVELS[lv];
}

/** 今天已经用掉的「转出」额度：转账 + 发红包 + 提现（都不含被退回的） */
function todayOutAmount(userId) {
  const day0 = localDayStart();
  let sum = 0;
  (db.transfers || []).forEach((t) => {
    if (t.fromId !== userId) return;
    if (new Date(t.createdAt).getTime() < day0) return;
    sum += Number(t.amount) || 0;
  });
  (db.redpackets || []).forEach((r) => {
    if (r.fromId !== userId) return;
    if (new Date(r.createdAt).getTime() < day0) return;
    sum += Number(r.total) || 0;
  });
  readWalletOps().ops.forEach((o) => {
    if (o.userId !== userId || o.kind !== 'withdraw') return;
    if (new Date(o.createdAt).getTime() < day0) return;
    sum += Number(o.amount) || 0;
  });
  return Math.round(sum * 100) / 100;
}

/** 花钱前的额度检查：过不去就返回一句人话（微信也是这么提示的） */
function walletLimitCheck(user, amount) {
  const info = walletLevelInfo(user);
  if (amount > info.single) {
    return { error: '单笔最多 ' + money(info.single) + '（你现在的账户等级：' + info.name + '）。升级账户就能提高额度 → 我 → 服务 → 钱包 → 账户升级服务' };
  }
  const used = todayOutAmount(user.id);
  if (used + amount > info.day) {
    return { error: '今天的额度只剩 ' + money(Math.max(0, info.day - used)) + ' 了（单日上限 ' + money(info.day) + '）。升级账户能提高额度' };
  }
  return { ok: true, used, left: Math.round((info.day - used) * 100) / 100, level: info.level };
}

/* --------------------------------------------------- 红包（微信那一套）
   规则和微信对齐：
   · 单聊只发 1 个（普通红包）；群聊可以设个数，分「拼手气」和「普通红包」
   · 发的时候先从发红包的人余额里扣掉全部金额
   · 发红包的人不能抢自己的红包；同一个人在一个红包里只能抢一次
   · 拼手气用「二倍均值」随机分（微信就是这套算法），普通红包每人一样、余数给最后一个
   · 抢完了 status=done；24 小时一到，没被抢完的剩下的钱自动退回给发红包的人
   · 群里每被抢走一个，多一条「XXX 领取了你的红包」灰条
   ------------------------------------------------------------------ */

const rpRound2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

/* ---------------- 红包封面（微信那套：发红包时能挑封面） ----------------
   封面在后台「红包封面」页里配：名字 + 封面图 + 缩略图 + 主题色。
   每个用户可以选一个自己的封面（user.rpCover），发红包时不选就用默认封面。 */
const RP_COVERS_FILE = 'redpacket-covers.json';
let rpCoversCache = null;
const DEFAULT_RP_COVERS = {
  defaultId: 'cv_gold',
  covers: [
    { id: 'cv_gold', name: '金玉满堂', image: '/uploads/rpc-gold.png', thumb: '/uploads/rpc-gold-t.png', color: '#8E1412', enabled: true },
    { id: 'cv_cloud', name: '祥云纳福', image: '/uploads/rpc-cloud.png', thumb: '/uploads/rpc-cloud-t.png', color: '#0E332E', enabled: true },
    { id: 'cv_snow', name: '初雪', image: '/uploads/rpc-snow.png', thumb: '/uploads/rpc-snow-t.png', color: '#183355', enabled: true },
    { id: 'cv_pink', name: '喜欢你', image: '/uploads/rpc-pink.png', thumb: '/uploads/rpc-pink-t.png', color: '#B42C58', enabled: true }
  ]
};

function readRpCovers() {
  if (rpCoversCache) return rpCoversCache;
  let raw = null;
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, RP_COVERS_FILE), 'utf8')); } catch (e) { raw = null; }
  const cfg = Object.assign({}, DEFAULT_RP_COVERS, raw && typeof raw === 'object' ? raw : {});
  if (!Array.isArray(cfg.covers) || !cfg.covers.length) cfg.covers = DEFAULT_RP_COVERS.covers;
  cfg.covers = cfg.covers.map((c, i) => ({
    id: str(c && c.id, 30) || ('cv' + (i + 1)),
    name: str(c && c.name, 20) || '红包封面',
    image: str(c && c.image, 300),
    thumb: str(c && (c.thumb || c.image), 300),
    color: /^#[0-9a-fA-F]{6}$/.test(String((c && c.color) || '')) ? String(c.color) : '#B3241C',
    enabled: !(c && c.enabled === false)
  })).filter((c) => c.image);
  if (!cfg.covers.length) cfg.covers = DEFAULT_RP_COVERS.covers;
  if (!cfg.covers.some((c) => c.id === cfg.defaultId)) cfg.defaultId = cfg.covers[0].id;
  rpCoversCache = cfg;
  return cfg;
}

function saveRpCovers(next) {
  rpCoversCache = null;
  const cfg = readRpCovers();
  const merged = Object.assign({}, cfg, next || {});
  rpCoversCache = merged;
  try { writeJson(path.join(DATA_DIR, RP_COVERS_FILE), merged); } catch (e) { }
  return merged;
}

/** 这张封面能不能用：不能用就回退到默认封面 */
function rpCoverOf(id) {
  const cfg = readRpCovers();
  const hit = cfg.covers.find((c) => c.id === str(id, 30) && c.enabled);
  if (hit) return hit;
  return cfg.covers.find((c) => c.id === cfg.defaultId && c.enabled) || cfg.covers.find((c) => c.enabled) || null;
}

const rpClaims = (r) => (Array.isArray(r.claims) ? r.claims : []);
const rpClaimed = (r) => rpRound2(rpClaims(r).reduce((a, c) => a + (Number(c.amount) || 0), 0));
const rpLeftCount = (r) => Math.max(0, (Number(r.count) || 1) - rpClaims(r).length);
const rpLeftAmount = (r) => rpRound2((Number(r.total) || 0) - rpClaimed(r));
/** 手气最佳：抢得最多的那个（并列时取先抢的） */
function rpBest(r) {
  const list = rpClaims(r);
  if (!list.length) return null;
  return list.reduce((best, c) => ((Number(c.amount) || 0) > (Number(best.amount) || 0) ? c : best), list[0]);
}

/** 这次该抢到多少钱（微信「二倍均值」：随机区间 0.01 ~ 剩余平均值的两倍） */
function drawRedPacketAmount(r) {
  const leftCount = rpLeftCount(r);
  const leftAmount = rpLeftAmount(r);
  if (leftCount <= 0 || leftAmount <= 0) return 0;
  if (r.type === 'normal') {
    const each = rpRound2((Number(r.total) || 0) / (Number(r.count) || 1));
    return leftCount === 1 ? leftAmount : Math.min(each, leftAmount);
  }
  if (leftCount === 1) return leftAmount;                       // 最后一个把剩下的全拿走
  const avg = leftAmount / leftCount;
  const max = Math.max(0.01, Math.min(leftAmount - (leftCount - 1) * 0.01, avg * 2));
  const amount = rpRound2(0.01 + Math.random() * (max - 0.01));
  return Math.max(0.01, Math.min(amount, leftAmount - (leftCount - 1) * 0.01));
}

function redpacketSnapshot(r) {
  const list = rpClaims(r);
  const cover = rpCoverOf(r.coverId);
  return JSON.stringify({
    id: r.id,
    total: Number(r.total) || 0,
    count: Number(r.count) || 1,
    claimedCount: list.length,
    claimedIds: list.map((c) => c.userId),
    type: r.type || 'normal',            // lucky 拼手气 / normal 普通
    note: r.note || '恭喜发财，大吉大利',
    status: r.status,                    // pending 还有一个没抢 / done 抢完了 / refunded 过期退回
    expired: !!r.expired,                // true = 24 小时到了（还剩的时间就不算了）
    /* 封面：卡片和拆红包页按它画（发的时候用哪张就一直是哪张） */
    coverId: cover ? cover.id : '',
    coverName: cover ? cover.name : '',
    cover: cover ? cover.image : '',
    coverThumb: cover ? cover.thumb : '',
    coverColor: cover ? cover.color : '#B3241C',
    fromId: r.fromId,
    fromName: r.fromName || '',
    createdAt: r.createdAt,
    expiresAt: r.expiresAt,
    refundedAt: r.refundedAt || '',
    refundAmount: r.refundAmount || 0
  });
}

/** 把会话里那条红包消息的内容刷成最新状态（客户端按它画卡片 / 变色） */
function syncRedPacketMessage(r) {
  const chat = db.chats.find((c) => c.id === r.chatId);
  if (!chat) return null;
  const messages = loadMessages(chat.id);
  const msg = messages.find((m) => m.id === r.messageId);
  if (!msg) return null;
      msg.content = redpacketSnapshot(r);
      try {
        saveMessagesFile(chat.id, messages);
      } catch (err) { /* 忽略 */ }
  return msg;
}

function broadcastRedPacket(r, kind) {
  syncRedPacketMessage(r);
  const payload = {
    type: 'redpacket',
    event: kind || 'update',
    chatId: r.chatId,
    messageId: r.messageId,
    redpacket: JSON.parse(redpacketSnapshot(r))
  };
  /* 群红包：会话里每个人都要收到状态更新（谁抢了、抢完没有） */
  const chat = db.chats.find((c) => c.id === r.chatId);
  const targets = chat ? chat.memberIds.slice() : [r.fromId, r.toId];
  targets.filter(Boolean).forEach((id) => sendTo(id, payload));
}

/** 24 小时到了：没抢完的红包，把剩下的钱退回给发红包的人（已经抢走的照旧） */
function expireRedPackets() {
  const t = Date.now();
  let changed = 0;
  (db.redpackets || []).forEach((r) => {
    if (r.status !== 'pending') return;
    if (!(r.expiresAt && r.expiresAt <= t)) return;
    const left = rpLeftAmount(r);
    const from = findUser(r.fromId);
    if (from && left > 0) {
      /* 24 小时没抢完：剩下的原路退回，走统一入口（记总账 + 不会算错分） */
      applyMoney(from, left, { reason: '红包 24 小时未抢完退回', ref: r.id });
      sendTo(from.id, { type: 'balance', balance: from.balance });
    }
    r.refundAmount = left;
    r.refundedAt = now();
    /* 一个都没抢走 → refunded；抢过一部分 → done（卡片显示已过期，钱已退剩余） */
    r.status = rpClaims(r).length ? 'done' : 'refunded';
    r.expired = true;
    changed++;
    broadcastRedPacket(r, 'refunded');
  });
  if (changed) { saveUsers(); saveRedPackets(); }
  return changed;
}

/* ---------------------------------------------------------------- 安全中心 */

/** 从 UA 里认一下系统和浏览器，用于「登录设备」展示 */
function describeDevice(ua) {
  const s = String(ua || '');
  if (!s) return '未知设备';
  /* 自家 App 的 UA：别把它说成「浏览器 · 未知系统」（型号客户端会单独用请求头报） */
  if (/CHRISChat|XingYan|Luchat|xingyan/i.test(s)) {
    const osx = /iPhone|iPad|iPod/.test(s) ? 'iOS'
      : (/HarmonyOS|OpenHarmony/.test(s) ? 'HarmonyOS'
      : (/Android/.test(s) ? 'Android' : ''));
    return '星言 App' + (osx ? ' · ' + osx : '');
  }
  let os = '未知系统';
  if (/iPhone|iPad|iPod/.test(s)) os = 'iOS';
  else if (/Android/.test(s)) os = 'Android';
  else if (/Windows NT 10/.test(s)) os = 'Windows 10/11';
  else if (/Windows/.test(s)) os = 'Windows';
  else if (/Mac OS X/.test(s)) os = 'macOS';
  else if (/Linux/.test(s)) os = 'Linux';
  let br = '浏览器';
  if (/Edg\//.test(s)) br = 'Edge';
  else if (/OPR\//.test(s)) br = 'Opera';
  else if (/Chrome\//.test(s)) br = 'Chrome';
  else if (/Firefox\//.test(s)) br = 'Firefox';
  else if (/Safari\//.test(s)) br = 'Safari';
  return br + ' · ' + os;
}

/* 时间戳统一成「毫秒数字」：以前直接把 ISO 字符串发给客户端，客户端按数字解，
   整个 /api/devices 响应就解不出来了（用户看到的就是「还没有设备记录」）。 */
function msOf(v) {
  if (typeof v === 'number' && isFinite(v)) return v;
  const t = Date.parse(String(v || ''));
  return isFinite(t) ? t : 0;
}

/* 机器号 → 机型名（iPhone17,1 → iPhone 16 Pro）：老记录里存的是机器号，
   登录设备管理那一页要显示的是机型名。 */
const DEVICE_MODEL_NAMES = {
  'iPhone14,6': 'iPhone SE3', 'iPhone14,7': 'iPhone 14', 'iPhone14,8': 'iPhone 14 Plus',
  'iPhone15,2': 'iPhone 14 Pro', 'iPhone15,3': 'iPhone 14 Pro Max',
  'iPhone15,4': 'iPhone 15', 'iPhone15,5': 'iPhone 15 Plus',
  'iPhone16,1': 'iPhone 15 Pro', 'iPhone16,2': 'iPhone 15 Pro Max',
  'iPhone17,1': 'iPhone 16 Pro', 'iPhone17,2': 'iPhone 16 Pro Max',
  'iPhone17,3': 'iPhone 16', 'iPhone17,4': 'iPhone 16 Plus', 'iPhone17,5': 'iPhone 16e',
  'iPhone18,1': 'iPhone 17 Pro', 'iPhone18,2': 'iPhone 17 Pro Max',
  'iPhone18,3': 'iPhone 17', 'iPhone18,4': 'iPhone Air',
  'iPad14,8': 'iPad Air 11', 'iPad14,9': 'iPad Air 13', 'iPad16,5': 'iPad Pro 13'
};
function friendlyModelName(m) {
  const x = String(m == null ? '' : m).trim();
  if (!x) return '';
  if (DEVICE_MODEL_NAMES[x]) return DEVICE_MODEL_NAMES[x];
  if (/^(iPhone|iPad)\d+,\d+$/.test(x)) return x.toLowerCase().indexOf('ipad') === 0 ? 'iPad' : 'iPhone';
  return x;
}

function clientInfo(req) {
  const ua = String((req && req.headers && req.headers['user-agent']) || '');
  /* 真实来源 IP：先看连接本身，只有「从本机进来的」（内网穿透/反代都在本机）
     才信转发头 —— 否则局域网里随便伪造 X-Forwarded-For 就能绕过限流和封禁。 */
  let ip = String((req && req.socket && (req.socket.remoteAddress || '')) || '').replace('::ffff:', '');
  if (ip === '127.0.0.1' || ip === '::1' || ip === '') {
    const fwd = String((req && req.headers && req.headers['cf-connecting-ip']) || '').trim() ||
      String((req && req.headers && (req.headers['x-forwarded-for'] || '')) || '').split(',')[0].trim();
    if (fwd) ip = fwd.replace('::ffff:', '').trim();
  }
  ip = ip.replace('::ffff:', '').replace('::1', '127.0.0.1');
  /* 客户端自带的设备标识（iOS 端把 UUID 存 Keychain，请求头 X-Device-Id 带上来）。
     用它可以准确判断「是不是换了设备」，比拿 UA + IP 猜靠谱得多：
     UA 是几百万台 iPhone 共用的，同 UA 不算同一台设备。 */
  const deviceId = String((req && req.headers && req.headers['x-device-id']) || '')
    .replace(/[^0-9A-Za-z\-]/g, '').slice(0, 64);
  /* App 顺带把设备名 / 型号 / 系统报上来（「登录设备管理」那一页要显示
     「张三的 iPhone · iOS 19.1」这种）。老客户端不带这几个头，就退回按 UA 猜。 */
  const headOf = (k) => String((req && req.headers && req.headers[k]) || '').slice(0, 60);
  const model = headOf('x-device-model');
  const osName = headOf('x-device-os');
  const devName = headOf('x-device-name');
  return { ip, device: describeDevice(ua), deviceId, model, os: osName, name: devName };
}

/** 记一条登录 / 安全事件 */
function recordSecurity(userId, req, kind, extra) {
  const info = clientInfo(req);
  const row = Object.assign({ id: uid('lg'), userId, kind: kind || 'login', time: now(), ip: info.ip, device: info.device }, extra || {});
  db.security.logins.unshift(row);
  if (db.security.logins.length > 600) db.security.logins.length = 600;
  if (kind && kind !== 'login') { db.security.events.unshift(row); if (db.security.events.length > 300) db.security.events.length = 300; }
  saveSecurity();
  return row;
}

function securityScore(user, logins) {
  let score = 40;
  if (user.passwordUpdatedAt) score += 20;                 // 主动改过密码
  if (user.phone) score += 15;                             // 绑定了手机号
  if (user.region) score += 5;                             // 填了地区
  const devices = {};
  logins.forEach((l) => { devices[l.device] = (devices[l.device] || 0) + 1; });
  if (Object.keys(devices).length <= 2) score += 20;       // 登录设备不多
  else if (Object.keys(devices).length <= 4) score += 10;
  return Math.max(10, Math.min(100, score));
}

/* ============================================================
   安全分（照微信那套机制做的）
   分数区间 550~850，三个维度各 100 分：身份特质 · 支付行为 · 守约历史
   分档：<600 信用较差 · 600-649 信用中等 · 650-699 信用良好
        700-749 信用优秀 · >=750 信用极好
   数据全部来自真实记录（资料 / 登录设备 / 转账 / 记账 / 安全事件 / 违规）。
   ============================================================ */
function creditLevel(score) {
  if (score >= 750) return '信用极好';
  if (score >= 700) return '信用优秀';
  if (score >= 650) return '信用良好';
  if (score >= 600) return '信用中等';
  return '信用较差';
}

function creditScore(user) {
  const logins = db.security.logins.filter((x) => x.userId === user.id);
  const devices = {};
  logins.forEach((l) => { devices[l.device || '未知'] = 1; });
  const deviceCount = Object.keys(devices).length;
  const mineTransfers = (db.transfers || []).filter((t) => t && (t.fromId === user.id || t.toId === user.id));
  const sent = mineTransfers.filter((t) => t.fromId === user.id);
  const got = mineTransfers.filter((t) => t.toId === user.id);
  const gotPaid = got.filter((t) => t.status === 'received').length;
  const gotExpired = got.filter((t) => t.status === 'refunded').length;
  const payFails = logins.filter((l) => l.kind === 'pay-password-fail').length;
  const violated = (opsStore.violations || []).filter((v) => v && v.userId === user.id).length;
  const ledgerRows = (() => {
    try {
      const led = readJson(path.join(DATA_DIR, 'ledger.json'), { items: [] });
      return (Array.isArray(led.items) ? led.items : []).filter((x) => x.userId === user.id).length;
    } catch (e) { return 0; }
  })();
  const days = Math.floor((Date.now() - Date.parse(user.createdAt || now())) / 86400000);

  /* ---------- ① 身份特质：资料越全越像真人 ---------- */
  const idItems = [];
  let identity = 0;
  const addId = (label, ok, point, yes, no) => {
    if (ok) { identity += point; idItems.push({ label: label, ok: true, tip: yes }); }
    else idItems.push({ label: label, ok: false, tip: no });
  };
  addId('实名认证', !!(user.realName && user.idCardHash), 30, '已实名', '去「我 → 设置 → 实名认证」填姓名和身份证号');
  addId('绑定手机号', !!user.phone, 20, '已绑定', '绑手机号能加分，也更安全');
  addId('设置支付密码', hasPayPassword(user), 20, '已设置', '去「设置 → 支付密码」设一个');
  addId('填了地区', !!user.region, 10, '已填', '在「个人信息 → 地区」里选一个');
  addId('有头像和昵称', !!(user.avatar && user.nickname), 10, '已完善', '换张头像、起个昵称');
  addId('账号满 7 天', days >= 7, 10, '已满 ' + days + ' 天', '账号越久越稳，再用几天');
  identity = Math.min(100, identity);

  /* ---------- ② 支付行为：用得多、守规矩 ---------- */
  const payItems = [];
  let payment = 0;
  const sentN = sent.length;
  const payStep = sentN === 0 ? 0 : (sentN < 5 ? 25 : (sentN < 20 ? 45 : 60));
  payment += payStep;
  payItems.push({ label: '转过账', ok: sentN > 0, tip: sentN > 0 ? ('转过 ' + sentN + ' 笔') : '发过一次转账就有分' });
  const gotStep = gotPaid > 0 ? 15 : 0;
  payment += gotStep;
  payItems.push({ label: '收到过转账', ok: gotPaid > 0, tip: gotPaid > 0 ? ('收到 ' + gotPaid + ' 笔') : '别人转给你并收款后加分' });
  const paid = sent.filter((t) => t.status === 'received').length;
  payment += paid >= 5 ? 15 : (paid > 0 ? 8 : 0);
  payItems.push({ label: '完成过收款', ok: paid > 0, tip: paid > 0 ? ('对方收了 ' + paid + ' 笔') : '对方点「收钱」才算完成' });
  payment += ledgerRows > 0 ? 5 : 0;
  payItems.push({ label: '记过账', ok: ledgerRows > 0, tip: ledgerRows > 0 ? ('记了 ' + ledgerRows + ' 笔') : '跟 AI 说「记账 午饭 25」' });
  payment += (Number(user.balance) || 0) > 0 ? 5 : 0;
  payItems.push({ label: '零钱里有余额', ok: (Number(user.balance) || 0) > 0, tip: (Number(user.balance) || 0) > 0 ? '有余额' : '充一点零钱' });
  payment = Math.min(100, payment);

  /* ---------- ③ 守约历史：答应的事做到了没有 ---------- */
  const proItems = [];
  let promise = 0;
  const gotAll = gotPaid + gotExpired;
  const keptRate = gotAll === 0 ? 1 : gotPaid / gotAll;
  const keptPts = gotAll === 0 ? 30 : Math.round(45 * keptRate);
  promise += keptPts;
  proItems.push({
    label: '转账按时收款',
    ok: gotAll === 0 ? true : keptRate >= 0.9,
    tip: gotAll === 0 ? '还没有超时的记录' : (gotPaid + '/' + gotAll + ' 笔按时收了')
  });
  promise += gotExpired === 0 ? 20 : Math.max(0, 20 - gotExpired * 8);
  proItems.push({ label: '没有超时退回', ok: gotExpired === 0, tip: gotExpired === 0 ? '没有退回记录' : (gotExpired + ' 笔超过 24 小时没收') });
  promise += payFails === 0 ? 15 : Math.max(0, 15 - payFails * 5);
  proItems.push({ label: '支付密码没输错过', ok: payFails === 0, tip: payFails === 0 ? '没有错误记录' : ('输错过 ' + payFails + ' 次') });
  promise += violated === 0 ? 10 : 0;
  proItems.push({ label: '没有违规记录', ok: violated === 0, tip: violated === 0 ? '很干净' : ('有 ' + violated + ' 条违规记录') });
  promise += deviceCount <= 2 ? 10 : (deviceCount <= 4 ? 5 : 0);
  proItems.push({ label: '登录设备不多', ok: deviceCount <= 2, tip: deviceCount <= 2 ? (deviceCount + ' 台设备') : ('最近在 ' + deviceCount + ' 台设备上登录过，改个密码更安全') });
  promise = Math.min(100, promise);

  const score = Math.max(550, Math.min(850, 550 + identity + payment + promise));
  const tips = [];
  idItems.concat(payItems, proItems).forEach((it) => {
    if (!it.ok && tips.length < 4) tips.push(it.label + '：' + it.tip);
  });
  if (!tips.length) tips.push('各方面都很好，保持下去就行 👍');

  return {
    score: score,
    level: creditLevel(score),
    min: 550,
    max: 850,
    percent: Math.round(((score - 550) / 300) * 100),
    updatedAt: now(),
    dims: [
      { key: 'identity', label: '身份特质', score: identity, max: 100, items: idItems },
      { key: 'payment', label: '支付行为', score: payment, max: 100, items: payItems },
      { key: 'promise', label: '守约历史', score: promise, max: 100, items: proItems }
    ],
    tips: tips,
    stats: {
      deviceCount: deviceCount,
      sentCount: sentN,
      successCount: paid,
      expiredCount: gotExpired,
      ledgerCount: ledgerRows
    }
  };
}

function messagesFile(chatId) { return path.join(MSG_DIR, chatId + '.jsonl'); }

/* ============================================================
   上传文件（图片/语音/视频/文件）落盘加密
   格式：文件头 4 字节 "LUC1" + 16 字节 IV，后面是 AES-256-CTR 的密文。
   密钥按文件名派生（HMAC-SHA256(secret.key, "file:"+文件名)），**一个文件一把**。
   为什么用 CTR 而不是 GCM：视频/语音要支持 Range 分片（拖进度条），
   流式解密才做得到；媒体文件的完整性由签名链接 + 登录态保证。
   对外服务时在 sendFile 里解密到内存（热文件有缓存），代码看 readUploadPlain。
   ============================================================ */
const UPLOAD_MAGIC = Buffer.from('LUC1');
const uploadPlainCache = new Map();     // name -> Buffer（解密后的）
let uploadPlainCacheBytes = 0;

function uploadFileKey(name) {
  return crypto.createHmac('sha256', String(db.secret || 'chris')).update('file:' + name).digest();
}

function sealUploadBuffer(name, buf) {
  const iv = crypto.randomBytes(16);
  const c = crypto.createCipheriv('aes-256-ctr', uploadFileKey(name), iv);
  return Buffer.concat([UPLOAD_MAGIC, iv, c.update(buf), c.final()]);
}

/** 磁盘上的字节 → 明文；老明文文件（还没有 LUC1 头）原样返回 */
function openUploadBuffer(name, raw) {
  if (raw.length < 20 || !raw.subarray(0, 4).equals(UPLOAD_MAGIC)) return raw;
  const iv = raw.subarray(4, 20);
  const d = crypto.createDecipheriv('aes-256-ctr', uploadFileKey(name), iv);
  return Buffer.concat([d.update(raw.subarray(20)), d.final()]);
}

/** 读一个上传文件的明文（带小缓存：最多 24 个、总量 64MB） */
function readUploadPlain(file) {
  const name = path.basename(file);
  const hit = uploadPlainCache.get(name);
  if (hit) return hit;
  const buf = openUploadBuffer(name, fs.readFileSync(file));
  if (buf.length <= 8 * 1024 * 1024) {
    uploadPlainCache.set(name, buf);
    uploadPlainCacheBytes += buf.length;
    while (uploadPlainCacheBytes > 64 * 1024 * 1024 && uploadPlainCache.size > 1) {
      const first = uploadPlainCache.keys().next().value;
      const old = uploadPlainCache.get(first);
      uploadPlainCacheBytes -= old ? old.length : 0;
      uploadPlainCache.delete(first);
    }
  }
  return buf;
}

/** 只看 4 字节文件头判断「这个上传文件是不是加密落盘的」，不读整个文件 */
function uploadIsSealed(file) {
  let fd = null;
  try {
    fd = fs.openSync(file, 'r');
    const head = Buffer.alloc(4);
    if (fs.readSync(fd, head, 0, 4, 0) < 4) return false;
    return head.equals(UPLOAD_MAGIC);
  } catch (err) {
    return false;
  } finally {
    if (fd !== null) { try { fs.closeSync(fd); } catch (err) { } }
  }
}

/** CTR 计数器按「块偏移」往前推：AES-CTR 的第 N 个 16 字节块用 IV+N 当计数器，
    所以拖进度条要的那一段可以单独解密，不用把整个视频先解一遍。 */
function ctrCounterAt(ivRaw, blockIndex) {
  const counter = Buffer.from(ivRaw);
  let add = blockIndex;
  for (let i = 15; i >= 0 && add > 0; i -= 1) {
    const sum = counter[i] + (add % 256);
    counter[i] = sum & 0xff;
    add = Math.floor(add / 256) + (sum > 255 ? 1 : 0);
  }
  return counter;
}

/** 只解密 [start,end] 这一段明文（视频边下边播 / 拖进度条走这里）。
    以前每个 Range 请求都会把整个文件读出来解一遍再切一刀 —— 一条 12MB 的视频
    拖几下就是几百 MB 的磁盘读 + 解密，服务器白忙，播放器还等不到数据。 */
function readUploadRange(file, name, start, end) {
  const fd = fs.openSync(file, 'r');
  try {
    const ivRaw = Buffer.alloc(16);
    if (fs.readSync(fd, ivRaw, 0, 16, 4) < 16) throw new Error('文件头不完整');
    const blockStart = Math.floor(start / 16) * 16;
    const skip = start - blockStart;
    const need = end - blockStart + 1;
    const cipher = Buffer.alloc(need);
    let got = 0;
    while (got < need) {
      const n = fs.readSync(fd, cipher, got, need - got, 20 + blockStart + got);
      if (!n) break;
      got += n;
    }
    if (got < need) throw new Error('文件不完整');
    const d = crypto.createDecipheriv('aes-256-ctr', uploadFileKey(name), ctrCounterAt(ivRaw, blockStart / 16));
    const plain = Buffer.concat([d.update(cipher), d.final()]);
    return plain.subarray(skip, skip + (end - start + 1));
  } finally {
    try { fs.closeSync(fd); } catch (err) { }
  }
}

/** 整包发一个加密上传文件：边读边解，不再把十几 MB 的视频整块塞进内存 */
function streamUploadPlain(file, res) {
  const name = path.basename(file);
  let ivRaw = null;
  try {
    const fd = fs.openSync(file, 'r');
    try {
      ivRaw = Buffer.alloc(16);
      if (fs.readSync(fd, ivRaw, 0, 16, 4) < 16) ivRaw = null;
    } finally { fs.closeSync(fd); }
  } catch (err) { ivRaw = null; }
  if (!ivRaw) { fs.createReadStream(file).pipe(res); return; }
  const d = crypto.createDecipheriv('aes-256-ctr', uploadFileKey(name), ivRaw);
  const rs = fs.createReadStream(file, { start: 20 });
  const kill = () => { try { rs.destroy(); } catch (err) { } try { res.destroy(); } catch (err) { } };
  rs.on('error', kill);
  d.on('error', kill);
  res.on('close', () => { try { rs.destroy(); } catch (err) { } });
  rs.pipe(d).pipe(res);
}

/** 明文写进上传目录（照样加密落盘），返回文件名 */
function saveUploadPlain(plainBuf, ext) {
  const name = uid('file') + (ext || '.bin');
  fs.writeFileSync(path.join(UPLOAD_DIR, name), sealUploadBuffer(name, plainBuf));
  return name;
}

/** 把刚落盘的上传文件就地加密（先写 .tmp 再改名，避免半截文件被读到）。
    已经是密文的就跳过，返回磁盘上的大小。 */
function sealUploadInPlace(name) {
  const file = path.join(UPLOAD_DIR, name);
  try {
    const raw = fs.readFileSync(file);
    if (raw.length >= 20 && raw.subarray(0, 4).equals(UPLOAD_MAGIC)) return raw.length;
    fs.writeFileSync(file + '.tmp', sealUploadBuffer(name, raw));
    fs.renameSync(file + '.tmp', file);
    return fs.statSync(file).size;
  } catch (err) {
    return 0;
  }
}

/** ffmpeg 读不了加密文件：先解到临时文件，跑完必须删掉（调用方负责） */
function uploadTempPlain(name) {
  const base = path.basename(name).replace(/[^A-Za-z0-9._-]/g, '');
  const tmp = path.join(os.tmpdir(), 'chris-' + crypto.randomBytes(6).toString('hex') + '-' + base);
  fs.writeFileSync(tmp, openUploadBuffer(name, fs.readFileSync(path.join(UPLOAD_DIR, name))));
  return tmp;
}

/** 异步跑一条 ffmpeg/ffprobe：以前用 spawnSync，一张 10MB 视频能把整个服务卡住几十秒
    （所有人都变「一直在转圈」）。改成异步，事件循环一点不占。 */
function runFfAsync(exe, args, timeoutMs) {
  return new Promise((resolve) => {
    let done = false;
    let err = '';
    let child = null;
    const finish = (r) => { if (!done) { done = true; clearTimeout(timer); resolve(r); } };
    try {
      child = spawn(exe, args, { stdio: ['ignore', 'ignore', 'pipe'] });
    } catch (e) {
      resolve({ ok: false, err: String(e && e.message || e) });
      return;
    }
    if (child.stderr) child.stderr.on('data', (d) => { err = (err + d.toString()).slice(-2000); });
    const timer = setTimeout(() => {
      try { child.kill('SIGKILL'); } catch (e) { }
      finish({ ok: false, err: 'ffmpeg 超时' });
    }, Math.max(5000, Number(timeoutMs) || 180000));
    child.on('error', (e) => finish({ ok: false, err: String(e && e.message || e) }));
    child.on('close', (code) => finish({ ok: code === 0, code: code, err: err }));
  });
}

/** 把上传目录里还留在磁盘上的明文文件一次性改成密文（启动时跑，可重复） */
function migrateUploadsToEncrypted() {
  let files = 0, bytes = 0, skipped = 0;
  let names = [];
  try { names = fs.readdirSync(UPLOAD_DIR); } catch (err) { return 0; }
  for (const name of names) {
    const file = path.join(UPLOAD_DIR, name);
    let st;
    try { st = fs.statSync(file); } catch (err) { continue; }
    if (!st.isFile() || st.size < 20) { continue; }
    let head = Buffer.alloc(0);
    try { head = fs.readFileSync(file).subarray(0, 4); } catch (err) { continue; }
    if (head.equals(UPLOAD_MAGIC)) { skipped += 1; continue; }
    try {
      const raw = fs.readFileSync(file);
      fs.writeFileSync(file + '.tmp', sealUploadBuffer(name, raw));
      fs.renameSync(file + '.tmp', file);
      files += 1;
      bytes += raw.length;
    } catch (err) { /* 单个失败不影响其它 */ }
  }
  if (files) console.log('[上传加密] ' + files + ' 个文件（' + (bytes / 1024 / 1024).toFixed(1) + ' MB）已从明文改成密文（另有 ' + skipped + ' 个本来就是密文）');
  return files;
}

/* ============================================================
   聊天内容「落盘加密」
   背景：以前消息在服务器上是**明文 JSON**（拿到磁盘/备份就能直接看）。
   现在每条消息用 AES-256-GCM 单独加密后存一行：
     {"e":1,"iv":…,"tag":…,"ct":…}
   密钥不落在这个文件里，而是从 data/secret.key（32 字节）按会话 id 派生
   （HMAC-SHA256(secret, "msg:"+chatId)）—— 不同会话不同密钥，泄露一个不牵连别的。
   每条单独加密的好处：**追加还是 O(1)**（发消息那条热点路径不变慢），
   读取时一行一行解，搜索/审核/机器人也照常工作（服务端手里有密钥）。
   老的明文行仍然能读（openMessage 会认），启动时会一次性改成密文（见 migrateMessages）。
   ============================================================ */
const MSG_CRYPTO = {
  algo: 'aes-256-gcm',
  keyCache: new Map()
};

function chatMessageKey(chatId) {
  const id = String(chatId);
  const hit = MSG_CRYPTO.keyCache.get(id);
  if (hit) return hit;
  const key = crypto.createHmac('sha256', String(db.secret || 'chris')).update('msg:' + id).digest();
  if (MSG_CRYPTO.keyCache.size > 4000) MSG_CRYPTO.keyCache.clear();   // 别无限涨
  MSG_CRYPTO.keyCache.set(id, key);
  return key;
}

/** 把一条消息打成一行密文 */
function sealMessage(chatId, obj) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv(MSG_CRYPTO.algo, chatMessageKey(chatId), iv);
  const ct = Buffer.concat([c.update(Buffer.from(JSON.stringify(obj), 'utf8')), c.final()]);
  return JSON.stringify({
    e: 1,
    iv: iv.toString('base64'),
    tag: c.getAuthTag().toString('base64'),
    ct: ct.toString('base64')
  });
}

/** 读一行：密文解密，老明文原样返回 */
function openMessage(chatId, line) {
  const o = JSON.parse(line);
  if (!o || o.e !== 1) return o;                       // 旧数据（明文）：直接当消息用
  const d = crypto.createDecipheriv(MSG_CRYPTO.algo, chatMessageKey(chatId), Buffer.from(o.iv, 'base64'));
  d.setAuthTag(Buffer.from(o.tag, 'base64'));
  const pt = Buffer.concat([d.update(Buffer.from(o.ct, 'base64')), d.final()]).toString('utf8');
  return JSON.parse(pt);
}

/** 整文件重写（撤回、转账状态更新、导入历史都用它） */
function saveMessagesFile(chatId, list) {
  const body = list.map((m) => sealMessage(chatId, m)).join('\n');
  fs.writeFileSync(messagesFile(chatId), body ? body + '\n' : '', 'utf8');
}

/** 启动时把还留在磁盘上的明文消息文件改成密文（一次性、可重复跑） */
function migrateMessagesToEncrypted() {
  /* 一次性迁移：跑完在 data 下落个标记，之后每次启动直接跳过。
     以前每启动一次都要把上万个消息文件从头读一遍（profiler 里 readFileUtf8 占 6%+），
     聊天记录越多启动越慢 —— 压测副本上这一项就要 2~3 秒。 */
  const marker = path.join(DATA_DIR, '.messages-migrated');
  try { if (fs.existsSync(marker)) return 0; } catch (err) { /* 读不到标记就照常迁 */ }
  let files = 0, lines = 0, skipped = 0;
  let names = [];
  try { names = fs.readdirSync(MSG_DIR).filter((f) => f.endsWith('.jsonl')); } catch (err) { return 0; }
  for (const f of names) {
    const chatId = f.replace(/\.jsonl$/, '');
    const file = path.join(MSG_DIR, f);
    let raw = '';
    try { raw = fs.readFileSync(file, 'utf8'); } catch (err) { continue; }
    const rows = raw.split('\n').map((s) => s.trim()).filter(Boolean);
    if (!rows.length) continue;
    let plain = 0;
    for (const line of rows) {
      try { const o = JSON.parse(line); if (!o || o.e !== 1) plain += 1; } catch (err) { plain += 1; }
    }
    if (!plain) { skipped += 1; continue; }
    const out = [];
    for (const line of rows) {
      try {
        const obj = openMessage(chatId, line);
        if (obj && !obj.e) out.push(sealMessage(chatId, obj));
      } catch (err) { /* 坏行丢掉 */ }
    }
    try {
      fs.writeFileSync(file + '.tmp', out.join('\n') + '\n', 'utf8');
      fs.renameSync(file + '.tmp', file);
      files += 1;
      lines += out.length;
    } catch (err) { /* 写不动就留着，下次再迁 */ }
  }
  if (files) console.log('[落盘加密] ' + files + ' 个会话、' + lines + ' 条消息已从明文改成密文（另有 ' + skipped + ' 个本来就是密文）');
  try { fs.writeFileSync(marker, new Date().toISOString() + '\n', 'utf8'); } catch (err) { /* 写不了标记下次再迁一次，不影响正确性 */ }
  return files;
}

function loadMessages(chatId) {
  if (messageCache.has(chatId)) return messageCache.get(chatId);
  const file = messagesFile(chatId);
  const list = [];
  if (fs.existsSync(file)) {
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    for (const line of lines) {
      const t = line.trim();
      if (!t) continue;
      try { list.push(openMessage(chatId, t)); } catch (err) { /* 跳过坏行 */ }
    }
  }
  const trimmed = list.slice(-MAX_CACHE);
  messageCache.set(chatId, trimmed);
  return trimmed;
}

function appendMessage(chatId, message) {
  fs.appendFileSync(messagesFile(chatId), sealMessage(chatId, message) + '\n', 'utf8');
  // loadMessages 会重新读文件（里面已经有这条了），所以这里只在缓存里没有时才补一次，
  // 否则同一条系统消息会在内存里出现两遍（发公告、面对面建群时都能看到）
  const list = loadMessages(chatId);
  const last = list[list.length - 1];
  if (!last || last.id !== message.id) list.push(message);   // 只看尾巴，几万条也不拖慢
  if (list.length > MAX_CACHE) list.splice(0, list.length - MAX_CACHE);
}

/* ------------------------------------------------------------------ 鉴权 */

/* ------------------------------------------------------------------
   二维码：两条路
     ① 优先用 vendor/qrcode.js（Kazuhiko Arase 的 MIT 实现，纠错等级 H）——
        客户端要在二维码正中间盖一张方形头像，等级 L 盖住就扫不出来了，
        H 能容 30% 的错，盖 4% 面积完全没问题（微信的个人码也是 H）。
     ② 没装上 vendor 就回退到下面这套自研实现（字节模式 / 纠错等级 L /
        版本 1~5，单块不走交织），已经和 Python 的 qrcode 库逐格对拍
        （5 个样例、不同版本和掩码都一致）。
   用来做个人二维码、群二维码、授权登录二维码。
   ------------------------------------------------------------------ */
const QR = (function () {
  const CAP = { 1: 19, 2: 34, 3: 55, 4: 80, 5: 108 };
  const EC = { 1: 7, 2: 10, 3: 15, 4: 20, 5: 26 };
  const ALIGN = { 1: 0, 2: 18, 3: 22, 4: 26, 5: 30 };
  const qsize = (v) => v * 4 + 17;
  let vendorQR = null;
  try { vendorQR = require(path.join(__dirname, 'vendor', 'qrcode.js')); } catch (e) { vendorQR = null; }
  /** 用 vendor 那套出等级 H 的码（装不上就返回 null，调用方回退自研那套） */
  function encodeH(text) {
    if (typeof vendorQR !== 'function') return null;
    try {
      const q = vendorQR(0, 'H');
      q.addData(String(text));
      q.make();
      const n = q.getModuleCount();
      if (!n || n < 21) return null;
      const modules = [];
      for (let y = 0; y < n; y++) {
        const row = new Array(n);
        for (let x = 0; x < n; x++) row[x] = q.isDark(y, x) ? 1 : 0;
        modules.push(row);
      }
      return { size: n, modules: modules };
    } catch (e) { return null; }
  }
  const EXP = new Array(256), LOG = new Array(256);
  (function () {
    let x = 1;
    for (let i = 0; i < 255; i++) { EXP[i] = x; LOG[x] = i; x <<= 1; if (x & 0x100) x ^= 0x11d; }
    EXP[255] = EXP[0];
  })();
  const mul = (a, b) => (a === 0 || b === 0) ? 0 : EXP[(LOG[a] + LOG[b]) % 255];
  function rsGenPoly(n) {
    let p = [1];
    for (let i = 0; i < n; i++) {
      const np = new Array(p.length + 1).fill(0);
      for (let j = 0; j < p.length; j++) { np[j] ^= p[j]; np[j + 1] ^= mul(p[j], EXP[i]); }
      p = np;
    }
    return p;
  }
  function rsEncode(data, ecLen) {
    const gen = rsGenPoly(ecLen);
    const res = data.concat(new Array(ecLen).fill(0));
    for (let i = 0; i < data.length; i++) {
      const coef = res[i];
      if (coef === 0) continue;
      for (let j = 0; j < gen.length; j++) res[i + j] ^= mul(gen[j], coef);
    }
    return res.slice(data.length);
  }
  function dataCodewords(bytes, version) {
    const bits = [];
    const push = (v, n) => { for (let i = n - 1; i >= 0; i--) bits.push((v >> i) & 1); };
    push(4, 4);
    push(bytes.length, 8);
    bytes.forEach((b) => push(b, 8));
    const capBits = CAP[version] * 8;
    const term = Math.min(4, capBits - bits.length);
    if (term > 0) push(0, term);
    while (bits.length % 8 !== 0) bits.push(0);
    const out = [];
    for (let i = 0; i < bits.length; i += 8) {
      let b = 0;
      for (let j = 0; j < 8; j++) b = (b << 1) | bits[i + j];
      out.push(b);
    }
    let pad = 0xEC;
    while (out.length < CAP[version]) { out.push(pad); pad = pad === 0xEC ? 0x11 : 0xEC; }
    return out;
  }
  function buildFunctionPatterns(version) {
    const n = qsize(version);
    const m = [], reserved = [];
    for (let i = 0; i < n; i++) { m.push(new Array(n).fill(0)); reserved.push(new Array(n).fill(0)); }
    const mx = { m: m, reserved: reserved };
    const setFn = (x, y, dark) => {
      if (x < 0 || y < 0 || x >= n || y >= n) return;
      m[y][x] = dark ? 1 : 0; reserved[y][x] = 1;
    };
    const finder = (cx, cy) => {
      for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) {
        const d = Math.max(Math.abs(dx), Math.abs(dy));
        setFn(cx + dx, cy + dy, d !== 2 && d <= 3);
      }
    };
    finder(3, 3); finder(n - 4, 3); finder(3, n - 4);
    for (let i = 8; i < n - 8; i++) { setFn(i, 6, i % 2 === 0); setFn(6, i, i % 2 === 0); }
    if (version >= 2) {
      const c = ALIGN[version];
      for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) {
        const d = Math.max(Math.abs(dx), Math.abs(dy));
        setFn(c + dx, c + dy, d !== 1);
      }
    }
    for (let i = 0; i <= 8; i++) if (i !== 6) { setFn(i, 8, false); setFn(8, i, false); }
    for (let i = 0; i < 8; i++) { setFn(n - 1 - i, 8, false); setFn(8, n - 1 - i, false); }
    setFn(8, n - 8, true);
    return mx;
  }
  function placeData(mx, codewords) {
    const n = mx.m.length;
    let bitIdx = 0;
    const total = codewords.length * 8;
    const bitAt = (i) => (i < total) ? ((codewords[i >> 3] >> (7 - (i & 7))) & 1) : 0;
    let up = true;
    for (let right = n - 1; right >= 1; right -= 2) {
      if (right === 6) right = 5;
      for (let k = 0; k < n; k++) {
        const y = up ? (n - 1 - k) : k;
        for (let c = 0; c < 2; c++) {
          const x = right - c;
          if (mx.reserved[y][x]) continue;
          mx.m[y][x] = bitAt(bitIdx++);
        }
      }
      up = !up;
    }
  }
  const MASKS = [
    (y, x) => (x + y) % 2 === 0,
    (y) => y % 2 === 0,
    (y, x) => x % 3 === 0,
    (y, x) => (x + y) % 3 === 0,
    (y, x) => (Math.floor(y / 2) + Math.floor(x / 3)) % 2 === 0,
    (y, x) => ((x * y) % 2) + ((x * y) % 3) === 0,
    (y, x) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
    (y, x) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0
  ];
  function formatBits(mask) {
    const data = (1 << 3) | mask;             // 1 = 纠错等级 L
    let rem = data << 10;
    for (let i = 14; i >= 10; i--) if ((rem >> i) & 1) rem ^= 0x537 << (i - 10);
    return ((data << 10) | rem) ^ 0x5412;
  }
  function drawFormat(m, mask) {
    const n = m.length, bits = formatBits(mask);
    const bit = (i) => (bits >> (14 - i)) & 1;
    for (let i = 0; i <= 5; i++) m[8][i] = bit(i);
    m[8][7] = bit(6); m[8][8] = bit(7); m[7][8] = bit(8);
    for (let i = 9; i <= 14; i++) m[14 - i][8] = bit(i);
    for (let i = 0; i <= 6; i++) m[n - 1 - i][8] = bit(i);
    for (let i = 7; i <= 14; i++) m[8][n - 15 + i] = bit(i);
    m[n - 8][8] = 1;
  }
  function penalty(m) {
    const n = m.length;
    let p = 0;
    const runScore = (line) => {
      let s = 0, run = 1;
      for (let i = 1; i < line.length; i++) {
        if (line[i] === line[i - 1]) run++;
        else { if (run >= 5) s += run - 2; run = 1; }
      }
      if (run >= 5) s += run - 2;
      return s;
    };
    for (let y = 0; y < n; y++) p += runScore(m[y]);
    for (let x = 0; x < n; x++) p += runScore(m.map((r) => r[x]));
    for (let y = 0; y < n - 1; y++) for (let x = 0; x < n - 1; x++) {
      const v = m[y][x];
      if (m[y][x + 1] === v && m[y + 1][x] === v && m[y + 1][x + 1] === v) p += 3;
    }
    let dark = 0;
    for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) dark += m[y][x];
    p += Math.floor(Math.abs(dark * 100 / (n * n) - 50) / 5) * 10;
    return p;
  }
  function encode(text) {
    const h = encodeH(text);
    if (h) return h;
    const bytes = Array.from(Buffer.from(String(text), 'utf8'));
    let version = 0;
    for (let v = 1; v <= 5; v++) {
      if (Math.ceil((12 + bytes.length * 8) / 8) <= CAP[v]) { version = v; break; }
    }
    if (!version) return null;
    const codewords = dataCodewords(bytes, version).concat(rsEncode(dataCodewords(bytes, version), EC[version]));
    const base = buildFunctionPatterns(version);
    placeData(base, codewords);
    let best = null, bestScore = Infinity;
    for (let mask = 0; mask < 8; mask++) {
      const m = base.m.map((r) => r.slice());
      for (let y = 0; y < m.length; y++) for (let x = 0; x < m.length; x++) {
        if (!base.reserved[y][x] && MASKS[mask](y, x)) m[y][x] ^= 1;
      }
      drawFormat(m, mask);
      const s = penalty(m);
      if (s < bestScore) { bestScore = s; best = m; }
    }
    return { size: best.length, modules: best };
  }
  function svg(text, scale) {
    const r = encode(text);
    if (!r) return '';
    const q = Math.max(2, Math.min(12, Number(scale) || 6));
    const n = r.size, quiet = 2, total = (n + quiet * 2) * q;
    let path = '';
    for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) {
      if (r.modules[y][x]) path += 'M' + ((x + quiet) * q) + ' ' + ((y + quiet) * q) + 'h' + q + 'v' + q + 'h-' + q + 'z';
    }
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + total + ' ' + total + '" width="' + total + '" height="' + total + '">'
      + '<rect width="' + total + '" height="' + total + '" fill="#fff"/><path d="' + path + '" fill="#000"/></svg>';
  }
  return { encode: encode, svg: svg };
})();

function hashPassword(password, salt) {
  return crypto.scryptSync(String(password), salt, 64).toString('hex');
}

/** 两个字符串等长时用常量时间比较（防时序侧信道） */
function sameSecret(a, b) {
  const x = Buffer.from(String(a == null ? '' : a));
  const y = Buffer.from(String(b == null ? '' : b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

/* ---------------------------------------------------------------- 密码存储
   规矩：**数据库里不留明文**。登录密码、支付密码一律只有 salt + scrypt 哈希。
   历史包袱：早期版本和几个机器人账号是明文存的 —— 下面这个迁移函数把它们
   就地转成哈希（老密码不变，照旧能登录），然后把明文字段删掉。
   ------------------------------------------------------------------ */

/// 把一个账号的明文密码就地升级成哈希；返回是否改动过
function migrateUserSecrets(user) {
  if (!user) return false;
  let changed = false;
  if (typeof user.password === 'string' && user.password) {
    const salt = user.salt || crypto.randomBytes(16).toString('hex');
    user.salt = salt;
    if (!user.passwordHash) user.passwordHash = hashPassword(user.password, salt);
    delete user.password;
    changed = true;
  }
  if (typeof user.payPassword === 'string' && user.payPassword) {
    const psalt = user.paySalt || crypto.randomBytes(16).toString('hex');
    user.paySalt = psalt;
    if (!user.payPasswordHash) user.payPasswordHash = hashPassword(user.payPassword, psalt);
    delete user.payPassword;
    changed = true;
  }
  return changed;
}

/// 启动时扫一遍所有账号（只动有明文的那几个）
function migrateAllUserSecrets() {
  let n = 0;
  db.users.forEach((u) => { try { if (migrateUserSecrets(u)) n++; } catch (e) { } });
  if (n) {
    saveUsers();
    console.log('[密码迁移] ' + n + ' 个账号的明文密码已转成 scrypt 哈希（原密码不变）');
  }
  return n;
}

function verifyPassword(user, password) {
  if (!user) return false;
  /* 正常路径：salt + scrypt 哈希 */
  if (user.passwordHash && user.salt) {
    const attempt = Buffer.from(hashPassword(password, user.salt), 'hex');
    const stored = Buffer.from(user.passwordHash, 'hex');
    return attempt.length === stored.length && crypto.timingSafeEqual(attempt, stored);
  }
  /* 兜底：万一还有只有明文的账号，比对成功后就地升级（密码不用改） */
  if (typeof user.password === 'string' && user.password) {
    const ok = sameSecret(user.password, password);
    if (ok) { migrateUserSecrets(user); saveUsers(); }
    return ok;
  }
  return false;
}

/* 兼容老调用：以前这里是「假设一定有哈希」的实现，留着这个名字给别处用 */
function verifyPasswordHashed(user, password) {
  const attempt = Buffer.from(hashPassword(password, user.salt), 'hex');
  const stored = Buffer.from(user.passwordHash, 'hex');
  return attempt.length === stored.length && crypto.timingSafeEqual(attempt, stored);
}

/* ------------------------------------------------- 登录限流（防暴力破解）
   同一个 IP/账号 10 分钟内错 8 次 → 封 10 分钟；同一个 IP 连着错 30 次也封。
   成功登录会把计数清零。 */
const LOGIN_FAILS = new Map();          // key -> { n, first, until }
const LOGIN_WINDOW_MS = 10 * 60 * 1000;
const LOGIN_MAX = 8;                    // 单账号
const LOGIN_IP_MAX = 30;                // 单 IP（防止换账号扫）

function loginBlocked(key) {
  const rec = LOGIN_FAILS.get(key);
  if (!rec) return 0;
  if (rec.until && rec.until > Date.now()) return Math.ceil((rec.until - Date.now()) / 1000);
  if (rec.until && rec.until <= Date.now()) { LOGIN_FAILS.delete(key); return 0; }
  if (Date.now() - rec.first > LOGIN_WINDOW_MS) { LOGIN_FAILS.delete(key); return 0; }
  return 0;
}
function noteLoginFail(key) {
  const now = Date.now();
  const rec = LOGIN_FAILS.get(key);
  secStateDirty = true;
  if (!rec || now - rec.first > LOGIN_WINDOW_MS) {
    LOGIN_FAILS.set(key, { n: 1, first: now, until: 0 });
    return;
  }
  rec.n += 1;
  if (rec.n >= LOGIN_MAX) rec.until = now + LOGIN_WINDOW_MS;
}

/** 群二维码的邀请码：不带状态、随时可重算（改了密钥自动失效） */
/** 这条朋友圈给某个看的人看吗（作者自己永远能看） */
/* ---------------- 隐私 / 消息通知设置（照微信那两页的逻辑） ---------------- */
const DEFAULT_PRIVACY = {
  needVerify: true,        // 加我为朋友时需要验证
  strangerMoments: false,  // 允许陌生人查看朋友圈
  addByWx: true,           // 可以通过微信号找到我
  addByPhone: true,        // 可以通过手机号找到我
  addByGroup: true,        // 可以通过群聊加我
  addByQR: true,           // 可以通过二维码加我
  /* 朋友圈可见范围（微信「隐私 → 朋友圈可见范围」那一行）：
     '3d' 最近三天 / '6m' 最近半年 / 'all' 全部。只对**别人**生效 —— 自己永远看得见自己的全部。 */
  momentsRange: 'all'
};
const DEFAULT_NOTIFY = {
  on: true,                // 新消息通知
  sound: true,             // 声音
  vibrate: true,           // 振动
  showDetail: true,        // 通知显示消息详情
  muteStart: '',           // 免打扰开始（HH:MM，空=不启用）
  muteEnd: ''
};
function userPrivacy(u) {
  return Object.assign({}, DEFAULT_PRIVACY, (u && u.privacy) || {});
}
function userNotify(u) {
  return Object.assign({}, DEFAULT_NOTIFY, (u && u.notify) || {});
}

/** 这条朋友圈给某个看的人看吗（作者自己永远能看） */
function momentVisibleTo(m, viewerId) {
  if (!m) return false;
  if (m.authorId === viewerId) return true;
  const v = m.visibility || 'public';
  if (v === 'private') return false;
  if (v === 'partial') return (m.visibleTo || []).includes(viewerId);
  if (v === 'exclude') return !(m.hiddenFrom || []).includes(viewerId);
  return true;
}

/** 群二维码的邀请码：不带状态、随时可重算（改了密钥自动失效） */
/** 个人二维码：每个人的码不一样，扫了能加好友（不带状态，重启也不失效） */
function userCode(username) {
  const u = String(username || '');
  if (!u) return '';
  const sig = crypto.createHmac('sha256', db.secret || 'chris')
    .update('user:' + u).digest('base64url').replace(/[-_]/g, '').slice(0, 12);
  return u + '.' + sig;
}
/** 从个人码反查用户名：签名不对就当无效 */
function usernameFromUserCode(code) {
  const s = String(code || '');
  const i = s.lastIndexOf('.');
  if (i <= 0) return '';
  const u = s.slice(0, i);
  if (userCode(u) !== s) return '';
  return u;
}

/** 群二维码的邀请码：不带状态、随时可重算（改了密钥自动失效） */
function inviteCode(chatId) {
  const sig = crypto.createHmac('sha256', db.secret || 'chris')
    .update('invite:' + chatId).digest('base64url').replace(/[-_]/g, '').slice(0, 12);
  return chatId + '.' + sig;
}
/** 从邀请码反查群 id：签名不对就当无效 */
function chatIdFromInvite(code) {
  const s = String(code || '');
  const i = s.lastIndexOf('.');
  if (i <= 0) return '';
  const chatId = s.slice(0, i);
  if (inviteCode(chatId) !== s) return '';
  return chatId;
}

/** 往会话里塞一条系统消息（通话记录、退群、踢人、解散这种居中灰字），返回这条消息 */
function pushSystemMessage(chat, text) {
  chat.seq = (chat.seq || 0) + 1;
  const msg = {
    id: uid('m'), chatId: chat.id, seq: chat.seq, senderId: 'system',
    kind: 'system', content: text, createdAt: now(), recalled: false
  };
  appendMessage(chat.id, msg);
  return msg;
}
function clearLoginFails(keys) {
  keys.forEach((k) => LOGIN_FAILS.delete(k));
}

/* ================================================================ 安全总开关
   改 data/security.json 就能调，不用改代码、不用重装：
     signUploads  上传的文件必须带签名才能打开（默认 1）
     autoBan      某个 IP 一直失败就自动封禁（默认 1）
     strictSearch 只能「微信号/手机号」精确搜到人（默认 1，仿微信）
     adminIps     后台只允许这几个 IP（留空 = 只限局域网）
   ------------------------------------------------------------------ */
let secCache = { at: 0, cfg: null };
function secCfg() {
  const t = Date.now();
  if (secCache.cfg && t - secCache.at < 3000) return secCache.cfg;
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'security.json'), 'utf8')) || {}; } catch (err) { raw = {}; }
  const cfg = {
    signUploads: raw.signUploads === 0 ? 0 : 1,
    autoBan: raw.autoBan === 0 ? 0 : 1,
    strictSearch: raw.strictSearch === 0 ? 0 : 1,
    allowRecharge: raw.allowRecharge === 1 ? 1 : 0,   // 用户自己「充值」默认关闭（等于自己印钱）
    sliderLogin: raw.sliderLogin === 0 ? 0 : 1,       // 登录要不要先过滑动验证（默认要）
    sessionDays: Number(raw.sessionDays) > 0 ? Number(raw.sessionDays) : 180,   // 用户登录态保留天数
    adminKey: String(raw.adminKey || ''),             // 后台入口暗号（?k=…）
    adminIps: Array.isArray(raw.adminIps) ? raw.adminIps.map(String) : []
  };
  secCache = { at: t, cfg };
  return cfg;
}


/* ------------------------------------------------ 上传文件的「签名链接」
   以前 /uploads/xxx.jpg 谁拿到链接都能看。现在只有两种人能看：
     1) 带正确签名的链接（服务器发出去的每个路径都自动带上，客户端无感）
     2) 已登录的人（网页版带了会话 Cookie 也能直接看）
   签名里带 6 小时对齐的有效期，所以同一个文件在有效期内 URL 不变，缓存照样命中。 */
const UPLOAD_SIG_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const UPLOAD_SIG_WINDOW_MS = 6 * 60 * 60 * 1000;

function uploadSig(name, exp) {
  return crypto.createHmac('sha256', String(db.secret || 'no-secret'))
    .update(name + '|' + exp).digest('hex').slice(0, 32);
}
function signedUploadUrl(name) {
  const exp = Math.floor((Date.now() + UPLOAD_SIG_TTL_MS) / UPLOAD_SIG_WINDOW_MS) * UPLOAD_SIG_WINDOW_MS;
  return '/uploads/' + name + '?e=' + exp + '&s=' + uploadSig(name, exp);
}
function uploadSigOk(name, exp, sig) {
  if (!name || !exp || !sig) return false;
  if (Number(exp) < Date.now()) return false;
  const want = uploadSig(name, Number(exp));
  const a = Buffer.from(String(sig));
  const b = Buffer.from(want);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

/* ---------------- App 安装包：限时签名下载 ----------------
   以前 /Luchat.ipa 是裸直链，谁知道地址谁都能下。现在改成：
     · 下载入口 /download（带登录会话，或带后台暗号 ?k=xxx）→ 302 到一条**限时签名**链接
     · 裸直链在没有签名时：过渡期内**仍然放行**（老版本 App 只会开直链，
       不然它们永远更新不了），过渡期一到（data/download.json 的 requireSigAfter）就 403
   ⚠ 安装包是**未签名**的，别人下了也装不上；这层主要是防"直链到处传"，不是防破解。 */
const APP_IPA_NAME = 'Luchat.ipa';
const APP_DOWNLOAD_TTL_MS = 30 * 60 * 1000;      // 签名链接 30 分钟有效

/* 安装包直链的开关（按用户定的规矩：用包的时候公开，其他时间私有）
   data/download.json:
     { "mode": "open" }               → 谁都下（发新版、拉新用户的时候用）
     { "mode": "gated" }              → 直链 403，只能靠 /download 换的限时签名链接
     { "mode": "open", "modeUntil": 1793000000000 }  → 到点自动切成 gated（可选） */
function downloadCfg() {
  const file = path.join(DATA_DIR, 'download.json');
  let cfg = readJson(file, null);
  if (!cfg || !cfg.mode) {
    cfg = { mode: 'open', createdAt: now() };     // 默认公开：不影响现有用户装包
    try { writeJson(file, cfg); } catch (err) { /* 写不进也先按默认来 */ }
  }
  /* 定时收口：写了 modeUntil，时间一到就当 gated（不用人记着切） */
  if (cfg.mode === 'open' && Number(cfg.modeUntil) > 0 && Date.now() > Number(cfg.modeUntil)) {
    return Object.assign({}, cfg, { mode: 'gated' });
  }
  return cfg;
}

function appDownloadOpen() {
  try { return downloadCfg().mode !== 'gated'; } catch (err) { return true; }
}

/** 限时签名链接（绝对地址，手机点开就能下） */
function appDownloadUrl(req) {
  const exp = Math.floor((Date.now() + APP_DOWNLOAD_TTL_MS) / 60000) * 60000;
  const host = String(req.headers.host || 'aa.x8iu.com').split(':')[0];
  return 'https://' + host + '/' + APP_IPA_NAME + '?e=' + exp + '&s=' + uploadSig(APP_IPA_NAME, exp);
}

/** 这个 IPA 请求带的签名对不对 */
function appDownloadSigOk(q) {
  if (!q) return false;
  return uploadSigOk(APP_IPA_NAME, q.get('e'), q.get('s'));
}
/* 出站统一把 /uploads/xxx 换成长签名链接（HTTP 和 WebSocket 都走这里） */
const UPLOAD_URL_RE = /\/uploads\/([A-Za-z0-9._-]+)(?:\?[^"\\]*)?/g;
function signUploadsInText(text) {
  if (!secCfg().signUploads) return text;
  return text.replace(UPLOAD_URL_RE, (m, name) => signedUploadUrl(name));
}

/* ------------------------------------------------ 自动封禁（小黑屋）
   同一个 IP 在 10 分钟里失败 60 次（未登录取数据 / 后台越权 / 传错密码），
   直接关 1 小时。状态写进 data/security-state.json，**重启也不会清空**。 */
const BAN_WINDOW_MS = 10 * 60 * 1000;
const BAN_STRIKES = 60;
const BAN_MS = 60 * 60 * 1000;
const ipStrikes = new Map();     // ip -> { t, n }
const ipBans = new Map();        // ip -> until(ms)
let secStateDirty = false;

function securityStatePath() { return path.join(DATA_DIR, 'security-state.json'); }
function loadSecurityState() {
  try {
    const raw = JSON.parse(fs.readFileSync(securityStatePath(), 'utf8')) || {};
    Object.keys(raw.fails || {}).forEach((k) => {
      const r = raw.fails[k];
      if (r && r.until > Date.now()) LOGIN_FAILS.set(k, { n: r.n || 0, first: r.first || Date.now(), until: r.until });
      else if (r && Date.now() - (r.first || 0) < LOGIN_WINDOW_MS) LOGIN_FAILS.set(k, { n: r.n || 0, first: r.first, until: 0 });
    });
    Object.keys(raw.bans || {}).forEach((ip) => {
      /* 本机/服务器自己的 IP 不封（旧的误封记录也在这里被忽略掉） */
      if (raw.bans[ip] > Date.now() && bannableIp(ip)) ipBans.set(ip, raw.bans[ip]);
    });
    Object.keys(raw.strikes || {}).forEach((ip) => {
      const r = raw.strikes[ip];
      if (r && Date.now() - (r.t || 0) < BAN_WINDOW_MS) ipStrikes.set(ip, { t: r.t, n: r.n || 0 });
    });
  } catch (err) { /* 没有这个文件就是第一次跑 */ }
}
function saveSecurityState() {
  if (!secStateDirty) return;
  secStateDirty = false;
  const fails = {}, bans = {}, strikes = {};
  LOGIN_FAILS.forEach((v, k) => { fails[k] = v; });
  ipBans.forEach((v, k) => { bans[k] = v; });
  ipStrikes.forEach((v, k) => { strikes[k] = v; });
  try { writeJson(securityStatePath(), { fails, bans, strikes, savedAt: now() }); } catch (err) { /* 忽略 */ }
}
setInterval(saveSecurityState, 10 * 1000);
process.on('SIGINT', () => { saveSecurityState(); process.exit(0); });

/** 记一次「不怀好意」的行为，够了就封 */
/* 服务器自己这台机器的 IP（含本机回环）永远不进小黑屋 ——
   不然测试脚本或者自己手滑刷几次，就把自己锁在门外了。 */
let localIpCache = { at: 0, set: null };
function localIpSet() {
  const t = Date.now();
  if (localIpCache.set && t - localIpCache.at < 60000) return localIpCache.set;
  const set = new Set(['127.0.0.1', '::1', 'localhost', '']);
  try {
    const nets = os.networkInterfaces();
    Object.keys(nets).forEach((name) => (nets[name] || []).forEach((x) => {
      if (x.address) set.add(String(x.address).replace('::ffff:', '').replace('::1', '127.0.0.1'));
    }));
  } catch (err) { /* 忽略 */ }
  localIpCache = { at: t, set };
  return set;
}
function bannableIp(ip) {
  return !!ip && !localIpSet().has(String(ip).replace('::ffff:', ''));
}

/** 服务器自己在局域网里的地址（给内置 TURN / 生成链接用） */
function primaryLanIp() {
  try {
    const nets = os.networkInterfaces();
    const names = Object.keys(nets);
    for (let i = 0; i < names.length; i += 1) {
      const list = nets[names[i]] || [];
      for (let k = 0; k < list.length; k += 1) {
        const x = list[k];
        if (x.family === 'IPv4' && !x.internal && /^192\.168\.|^10\.|^172\.(1[6-9]|2\d|3[01])\./.test(x.address)) {
          return x.address;
        }
      }
    }
    for (let i = 0; i < names.length; i += 1) {
      const list = nets[names[i]] || [];
      for (let k = 0; k < list.length; k += 1) {
        if (list[k].family === 'IPv4' && !list[k].internal) return list[k].address;
      }
    }
  } catch (err) { /* 忽略 */ }
  return '127.0.0.1';
}

function strikeIp(ip, why) {
  if (riskOff()) return;
  if (!ip) return;
  const t = Date.now();
  let r = ipStrikes.get(ip);
  if (!r || t - r.t > BAN_WINDOW_MS) { r = { t, n: 0 }; ipStrikes.set(ip, r); }
  r.n += 1;
  secStateDirty = true;
  if (secCfg().autoBan && bannableIp(ip) && r.n >= BAN_STRIKES && !ipBans.has(ip)) {
    ipBans.set(ip, t + BAN_MS);
    secStateDirty = true;
    saveSecurityState();            // 立刻落盘，别等 10 秒的定时器
    console.log('[安全] 自动封禁 IP ' + ip + ' 1 小时（' + why + '，10 分钟内失败 ' + r.n + ' 次）');
  }
}
function ipBanRemain(ip) {
  if (riskOff()) return 0;
  const until = ipBans.get(ip);
  if (!until) return 0;
  if (until <= Date.now()) { ipBans.delete(ip); return 0; }
  return Math.ceil((until - Date.now()) / 1000);
}

/** 后台能不能访问：白名单优先，其次看「只允许局域网」 */
function adminIpOk(ip) {
  /* 本机和局域网永远放行（服务器上自己 curl、内网办公都靠它） */
  if (ip === '127.0.0.1' || ip === '::1' || isLanAddress(ip)) return true;
  /* 注意：不能读 secCfg()，它只保留自己认识的那几个字段，新加的开关会被它吃掉。
     这里直接读 data/security.json（后台请求很少，读文件不影响性能）。 */
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'security.json'), 'utf8')); } catch (e) { raw = {}; }
  /* 手工白名单优先（写了名单就只认名单） */
  const list = Array.isArray(raw.adminIps) ? raw.adminIps : [];
  if (list.length) return list.indexOf(ip) >= 0;
  /* 只允许国内 IP：后台从此不给境外访问（那个新加坡 IP 就是这么被挡掉的） */
  if (raw.adminCnOnly) return isCnIp(ip);
  return !adminLanOnlyOn();
}

/* ============================================================
   后台访问白名单（严格模式）：名单里的 IP 才能碰后台，
   不在名单里的一律按「这个页面/接口不存在」处理 —— 404，不给任何提示，
   扫描器扫过去只能看到和随便乱输路径一样的 404。
   名单存在 data/whitelist.json（后台「访问白名单」页可以改）。
   本机 127.0.0.1 永远放行：服务器上自己的脚本、看门狗都靠它。
   ============================================================ */
const WHITELIST_FILE = path.join(DATA_DIR, 'whitelist.json');
let whitelistCache = null;      // { at, ips }
function adminWhitelist() {
  const t = Date.now();
  if (whitelistCache && t - whitelistCache.at < 3000) return whitelistCache.ips;
  let raw = null;
  try { raw = JSON.parse(fs.readFileSync(WHITELIST_FILE, 'utf8')); } catch (err) { raw = null; }
  const ips = (raw && Array.isArray(raw.ips) ? raw.ips : [])
    .map((x) => String(x || '').trim()).filter(Boolean);
  whitelistCache = { at: t, ips };
  return ips;
}
function saveAdminWhitelist(ips) {
  const list = Array.from(new Set((ips || []).map((x) => String(x || '').trim()).filter(Boolean))).slice(0, 200);
  writeJson(WHITELIST_FILE, { ips: list, updatedAt: now() });
  whitelistCache = { at: Date.now(), ips: list };
  return list;
}
/** 后台放行判定：本机永远行；名单非空就只认名单；名单为空时退回老规则（避免把自己关在门外） */
function adminAllowed(ip) {
  const s = String(ip || '').replace('::ffff:', '');
  if (s === '127.0.0.1' || s === '::1' || s === '') return true;
  const list = adminWhitelist();
  if (list.length) {
    /* 三种写法都认（手机 IP 老是变，光写完整 IP 很容易把自己关在门外）：
       · 完整 IP：112.22.85.173
       · 前缀：  39.144.        ← 换基站也还是这一段
       · CIDR：  39.144.0.0/16 */
    for (const one of list) {
      if (one === s) return true;
      if (one.charAt(one.length - 1) === '.' && s.indexOf(one) === 0) return true;
      if (one.indexOf('/') > 0 && cidrMatch(s, one)) return true;
    }
    return false;
  }
  return adminIpOk(s);
}

/** 这个 IP 在不在某段 CIDR 里（39.144.0.0/16 这种） */
function cidrMatch(ip, cidr) {
  const parts = String(cidr).split('/');
  const bits = Number(parts[1]);
  const a = ipToInt(parts[0]);
  const b = ipToInt(ip);
  if (a < 0 || b < 0 || !(bits >= 0 && bits <= 32)) return false;
  const mask = bits === 0 ? 0 : ((0xFFFFFFFF << (32 - bits)) >>> 0);
  return (((a & mask) >>> 0) === ((b & mask) >>> 0));
}

/* ---------- 中国 IPv4 段（APNIC 委派数据，生成在 data/cn-ips.json，二分查找） ---------- */
let cnRangesCache = null;
function cnRanges() {
  if (cnRangesCache) return cnRangesCache;
  try {
    const raw = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'cn-ips.json'), 'utf8'));
    cnRangesCache = Array.isArray(raw.ranges) ? raw.ranges : [];
  } catch (e) { cnRangesCache = []; }
  return cnRangesCache;
}

function ipToInt(ip) {
  const p = String(ip || '').replace(/^::ffff:/, '').split('.');
  if (p.length !== 4) return -1;
  let n = 0;
  for (const s of p) {
    const v = Number(s);
    if (!(v >= 0 && v <= 255)) return -1;
    n = n * 256 + v;
  }
  return n;
}

/** 这个 IP 是不是国内（表里没有就返回 false，宁可挡错也不放境外进后台） */
function isCnIp(ip) {
  const ranges = cnRanges();
  if (!ranges.length) return false;
  const n = ipToInt(ip);
  if (n < 0) return false;
  let lo = 0, hi = ranges.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const [a, b] = ranges[mid];
    if (n < a) hi = mid - 1;
    else if (n > b) lo = mid + 1;
    else return true;
  }
  return false;
}

/* ============================================================ 管理员后台加固
   ① 保密入口：后台页面要带暗号（?k=…）才能打开，乱试的路由一律 404
   ② 会话绑 IP：令牌里写进登录时的 IP，换个 IP 用不了；有效期缩到 8 小时
   ③ 登录锁定：5 次错密码锁 30 分钟（按账号 + 按 IP 各算一遍） */
const OPS_SESSION_TTL_MS = 8 * 60 * 60 * 1000;
const OPS_LOGIN_MAX = Number(process.env.OPS_LOGIN_MAX) || 20;    // 错 20 次才锁（以前 5 次太容易把自己锁住）
const OPS_LOCK_MS = Number(process.env.OPS_LOCK_MS) || 2 * 60 * 1000;   // 锁 2 分钟（以前 30 分钟）
const opsFails = new Map();          // key -> { n, until }

function opsLoginBlocked(key) {
  const r = opsFails.get(key);
  if (!r) return 0;
  if (r.until && r.until > Date.now()) return Math.ceil((r.until - Date.now()) / 1000);
  if (r.until && r.until <= Date.now()) { opsFails.delete(key); return 0; }
  return 0;
}
function noteOpsFail(key) {
  const t = Date.now();
  let r = opsFails.get(key);
  if (!r || (r.until && r.until <= t)) r = { n: 0, until: 0 };
  r.n += 1;
  if (r.n >= OPS_LOGIN_MAX) r.until = t + OPS_LOCK_MS;
  opsFails.set(key, r);
}
function clearOpsFails(keys) { keys.forEach((k) => opsFails.delete(k)); }

/** 后台入口暗号：data/security.json 里的 adminKey（第一次会自动生成） */
function ensureAdminKey() {
  try {
    const file = path.join(DATA_DIR, 'security.json');
    let raw = {};
    try { raw = JSON.parse(fs.readFileSync(file, 'utf8')) || {}; } catch (err) { raw = {}; }
    /* 已经有密文（adminKeyHash）就不要再生成新的明文了 —— 以前这里会在升级成密文后
       又随机生成一个明文暗号，把用户的旧暗号顶掉，表现就是「暗号不对，进不去」 */
    if (!raw.adminKey && !raw.adminKeyHash) {
      raw.adminKey = crypto.randomBytes(9).toString('base64url').replace(/[-_]/g, '').slice(0, 10);
      writeJson(file, raw);
    }
    secCache = { at: 0, cfg: null };
    return String(raw.adminKey);
  } catch (err) { return ''; }
}
function adminEntryOk(req, params) {
  const q = params && params.get ? String(params.get('k') || '') : '';
  const c = parseCookies(req).chris_admin_key || '';
  /* 暗号在数据里是密文（adminKeyHash + 盐）：这里两个来源都用哈希校验 */
  if (q && adminKeyOk(q)) return true;
  if (c && adminKeyOk(c)) return true;
  return false;
}
/** 登录 IP 指纹：写进后台令牌，换 IP 就失效 */
function ipFingerprint(ip) {
  return crypto.createHmac('sha256', adminAuth.secret).update('ip:' + String(ip || '')).digest('base64url').slice(0, 16);
}

/* 明文 http 登录 App 的提醒：不是拒绝（老 App 还得能用），
   而是在日志和审计里留一条，方便知道哪台设备还在用 http。 */
const plainLoginSeen = new Map();   // ip -> 最后提醒时间
function securityNotePlainLogin(req) {
  try {
    const ip = clientInfo(req).ip;
    const last = plainLoginSeen.get(ip) || 0;
    if (Date.now() - last < 60000) return;
    plainLoginSeen.set(ip, Date.now());
    console.log('[安全提醒] 有设备还在用明文 http 登录（' + ip + '），建议装上内置 https 地址的新版 App');
  } catch (err) { /* 忽略 */ }
}

/* 明文 ws 的提醒（同样只提醒，不拦） */
const plainWsSeen = new Map();
function securityNotePlainWs(ip) {
  const last = plainWsSeen.get(ip) || 0;
  if (Date.now() - last < 120000) return;
  plainWsSeen.set(ip, Date.now());
  console.log('[安全提醒] 有设备还在用明文 ws:// 收发实时消息（' + ip + '）');
}

/** 本机 / 局域网地址。
    明文口（5180）只留给它们：服务器自己的脚本、同一内网的调试机。
    公网来的明文请求一律挡掉 —— 不然密码、令牌会以明文过网（中间人抓包就能用）。 */
function isLocalOrLan(ip) {
  const s = String(ip || '').replace(/^::ffff:/, '');
  if (!s) return false;
  if (s === '127.0.0.1' || s === '::1' || s === 'localhost') return true;
  if (/^10\./.test(s)) return true;
  if (/^192\.168\./.test(s)) return true;
  if (/^172\.(1[6-9]|2\d|3[01])\./.test(s)) return true;
  if (/^169\.254\./.test(s)) return true;              // link-local
  if (/^f[cd][0-9a-f]{2}:/i.test(s)) return true;      // IPv6 ULA
  if (/^fe80:/i.test(s)) return true;                  // IPv6 link-local
  return false;
}

/** 后台登录必须走加密通道：明文 http 会把密码暴露给同网段的人 */
function httpsHint(req) {
  const host = String(req.headers.host || '').split(':')[0] || '192.168.2.7';
  return '后台登录必须走加密通道：请用 https://' + host + ':5443/manage.html 打开后台再登录'
    + '（http 明文会被同一个 Wi-Fi 下的人抓到密码和暗号）';
}

/* 一次性免密登录链接（只有超级管理员能生成）：
   用来「点开就直接以某个角色进后台看」，不用输密码。
   安全设计：① 5 分钟过期 ② 只能用一次 ③ 绑定打开它的那个 IP ④ 用掉后立刻从地址里消失 ⑤ 记审计日志 */
const opsMagic = new Map();      // token -> { adminId, exp, used }
function newMagicToken(adminId, minutes) {
  const token = crypto.randomBytes(18).toString('hex');
  opsMagic.set(token, { adminId, exp: Date.now() + Math.min(30, Math.max(1, minutes || 5)) * 60000, used: false });
  if (opsMagic.size > 200) { const first = opsMagic.keys().next().value; opsMagic.delete(first); }
  return token;
}
function takeMagicToken(token) {
  const rec = opsMagic.get(String(token || ''));
  if (!rec) return null;
  opsMagic.delete(String(token));           // 一次性：取出来就作废
  if (rec.used || rec.exp < Date.now()) return null;
  const admin = opsStore.admins.find((a) => a.id === rec.adminId && !a.disabled);
  return admin || null;
}

/* 支付密码（6 位数字，安全中心里设置，转账确认时校验） */
function verifyPayPassword(user, password) {
  if (!user) return false;
  /* 正常路径：salt + scrypt 哈希（和登录密码同一套） */
  if (user.payPasswordHash && user.paySalt) {
    const attempt = Buffer.from(hashPassword(password, user.paySalt), 'hex');
    const stored = Buffer.from(user.payPasswordHash, 'hex');
    return attempt.length === stored.length && crypto.timingSafeEqual(attempt, stored);
  }
  /* 兜底：万一还有明文存的支付密码，比对成功就地升级（原密码不变） */
  if (typeof user.payPassword === 'string' && user.payPassword) {
    const ok = sameSecret(user.payPassword, password);
    if (ok) { migrateUserSecrets(user); saveUsers(); }
    return ok;
  }
  return false;
}

/// 有没有设过支付密码（哈希或历史明文都算）
function hasPayPassword(user) {
  return !!(user && (user.payPasswordHash || user.payPassword));
}

/** 付钱之前一律要有支付密码（微信的规矩）：没设过就先去设，不给「直接付」这条路。
    以前是「没设过密码就直接扣钱」，等于谁都能不输密码把红包发出去。
    返回 true = 已经拦住并回过响应了，调用方直接 return。 */
function payPasswordGate(req, res, user, body, scene) {
  if (!hasPayPassword(user)) {
    fail(res, 428, '还没设置支付密码。为了安全，发红包 / 转账 / 付款都要先设一个（我 → 设置 → 账号与安全 → 支付密码）');
    return true;
  }
  if (body && body.face) return false;
  const pwd = String((body && body.password) || '').trim();
  if (!pwd) { fail(res, 422, '请输入支付密码'); return true; }
  if (!verifyPayPassword(user, pwd)) {
    recordSecurity(user.id, req, 'pay-password-fail', { note: (scene || '付款') + '时支付密码错' });
    fail(res, 422, '支付密码不正确');
    return true;
  }
  return false;
}

/* 端类型：手机 / 平板 / 电脑（客户端带 X-Device-Kind 头）。
   老客户端不带这个头 —— 一律当成手机，这样它照样会被新手机的登录顶下线。 */
function deviceKindOf(req) {
  const k = String((req && req.headers && req.headers['x-device-kind']) || '').toLowerCase();
  return (k === 'tablet' || k === 'desktop') ? k : 'phone';
}

/* 手机单点登录（A 方案：手机单点，平板 / 电脑可并存）：
   同一个账号在新手机上登录 →
     · phoneSession +1：旧手机令牌里的 ps 就对不上，之后每个请求都是 401 other_login
     · 给还连着长连接的旧手机推一张 kick 卡片（App 弹「你的账号在另一台设备上登录」）
   平板 / 电脑（kind = tablet / desktop）不参与，互不影响。 */
/* CHRIS_MULTIDEV_V1 多设备同时在线（用户要求「消息同步多端」）：
   开关放在 data/ui.json 的 multiDevice（管理页「开关」里能直接点，1 = 允许多台手机同时在线）。
   · 关（默认）：还是老规矩 —— 新手机一登，旧手机被顶下线（phoneSession +1，旧 token 立即失效）
   · 开：不顶、也不动 phoneSession，几台手机各自保持登录，消息/已读都通过同一条实时通道同步 */
function multiDeviceOn() {
  try {
    const ui = readJson(path.join(DATA_DIR, 'ui.json'), {});
    return Number(ui.multiDevice || 0) > 0;
  } catch (e) { return false; }
}
function kickOtherPhones(user, req) {
  if (!user) return 0;
  if (multiDeviceOn()) return 0;
  if (deviceKindOf(req) !== 'phone') return 0;
  const deviceId = String((req.headers && req.headers['x-device-id']) || '');
  user.phoneSession = (Number(user.phoneSession) || 0) + 1;
  const device = String((req.headers && req.headers['x-device-model']) || '').slice(0, 40) || '另一台手机';
  const set = connections.get(user.id);
  if (!set) return 0;
  let sent = 0;
  set.forEach((socket) => {
    if (String(socket.__kind || 'phone') !== 'phone') return;
    if (deviceId && String(socket.__deviceId || '') === deviceId) return;
    try {
      if (ws.sendText(socket, JSON.stringify({ type: 'kick', reason: 'otherLogin', device: device, at: Date.now() }))) sent += 1;
    } catch (e) { }
  });
  return sent;
}

function signToken(userId, req) {
  // v = 会话版本：改密码 / 退出其他设备时 +1，旧会话立刻失效
  const u = db.users.find((x) => x.id === userId);
  /* k = 端类型；手机令牌另有 ps（账号当前的手机会话号）。
     改这里的结构要连带看 currentUser 里的 ps 校验。 */
  const kind = deviceKindOf(req);
  const body = { sub: userId, v: (u && u.tokenVersion) || 0, exp: Date.now() + userSessionTtlMs(), k: kind };
  if (kind === 'phone') body.ps = Number((u && u.phoneSession) || 0);
  const payload = Buffer.from(JSON.stringify(body)).toString('base64url');
  const sig = crypto.createHmac('sha256', db.secret).update(payload).digest('base64url');
  return payload + '.' + sig;
}

function verifyTokenData(token) {
  if (!token || typeof token !== 'string') return null;
  const parts = token.split('.');
  if (parts.length !== 2) return null;
  const expect = crypto.createHmac('sha256', db.secret).update(parts[0]).digest('base64url');
  const a = Buffer.from(parts[1]);
  const b = Buffer.from(expect);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  try {
    const data = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
    if (typeof data.exp !== 'number' || data.exp <= Date.now()) return null;
    return data;
  } catch (err) {
    return null;
  }
}

function verifyToken(token) {
  const data = verifyTokenData(token);
  return data ? data.sub : null;
}

/* -------------------------------------------------------------- 管理员鉴权 */

function makeSecretRecord(password) {
  const salt = crypto.randomBytes(16).toString('hex');
  return {
    salt,
    hash: hashPassword(password, salt),
    secret: crypto.randomBytes(32).toString('hex'),
    updatedAt: now()
  };
}

function verifySecretRecord(record, password) {
  if (!record) return false;
  const attempt = Buffer.from(hashPassword(password, record.salt), 'hex');
  const stored = Buffer.from(record.hash, 'hex');
  return attempt.length === stored.length && crypto.timingSafeEqual(attempt, stored);
}

function signAdminToken() {
  const payload = Buffer.from(JSON.stringify({ scope: 'admin', exp: Date.now() + SESSION_TTL_MS })).toString('base64url');
  const sig = crypto.createHmac('sha256', adminAuth.secret).update(payload).digest('base64url');
  return payload + '.' + sig;
}

function verifyAdminToken(token) {
  if (!token || typeof token !== 'string') return false;
  const parts = token.split('.');
  if (parts.length !== 2) return false;
  const expect = crypto.createHmac('sha256', adminAuth.secret).update(parts[0]).digest('base64url');
  const a = Buffer.from(parts[1]);
  const b = Buffer.from(expect);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return false;
  try {
    const data = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8'));
    return data.scope === 'admin' && typeof data.exp === 'number' && data.exp > Date.now();
  } catch (err) {
    return false;
  }
}

const isAdmin = (req) => verifyAdminToken(parseCookies(req)[ADMIN_COOKIE]);

function adminCookie(token, maxAgeSeconds) {
  return ADMIN_COOKIE + '=' + encodeURIComponent(token) +
    '; Path=/; HttpOnly; SameSite=Lax; Max-Age=' + maxAgeSeconds;
}

function parseCookies(req) {
  const header = req.headers.cookie || '';
  const out = {};
  header.split(';').forEach((pair) => {
    const i = pair.indexOf('=');
    if (i === -1) return;
    const k = pair.slice(0, i).trim();
    if (k) out[k] = decodeURIComponent(pair.slice(i + 1).trim());
  });
  return out;
}

/** ==================== 群语音通话房间（2026-10-12） ====================
    一个群聊一个房间：roomId = 'gr_' + chatId 的哈希后缀（稳定、重启后按需重建）
    members: Map<userId, { at, name, avatar, muted }>
    frames : Map<userId, { seq, buf }>   —— 这一轮各人最新的一帧（40ms 一次混音） */
const callRooms = new Map();
function groupRoomId(chatId) {
  const h = crypto.createHash('sha1').update(String(chatId || '')).digest('hex').slice(0, 12);
  return 'gr_' + h;
}
function findRoomOf(userId) {
  for (const room of callRooms.values()) {
    if (room.members.has(userId)) return room;
  }
  return null;
}
/** 给房间里的成员发一条（exceptUserId 用来"别发回给发起人"） */
function roomSend(room, payload, exceptUserId) {
  room.members.forEach((_, uid) => {
    if (exceptUserId && uid === exceptUserId) return;
    callSend(findUser(uid), payload);
  });
}
/** 房间成员清单（发给客户端画头像墙） */
function roomRoster(room) {
  return Array.from(room.members.entries()).map(([uid, m]) => ({
    userId: uid, name: m.name || "", avatar: m.avatar || "", muted: !!m.muted
  }));
}
/** 房间混音：把这一轮每个人最新的那一帧按样本相加（16bit 单声道），再发给所有人 */
function roomMixTick(room) {
  try {
    const bufs = [];
    room.frames.forEach((f) => { if (f && f.buf && f.buf.length) bufs.push(f.buf); });
    room.frames.clear();
    if (!bufs.length) return;
    /* CHRIS_MIX_STRIP_SEQ_V1：客户端新发的帧前面带 2 字节序号（1282 = 1280 + 2），
       混音前先剥掉 —— 不然那两个字节会被当成音频样本混进去，混完的输出整段错位。
       剥完再混，混出来的还是干净的 1280（接收端按老格式播，群里不需要逐帧 PLC）。 */
    for (let k = 0; k < bufs.length; k++) {
      const b = bufs[k];
      if (b && b.length === 1282) bufs[k] = b.subarray(2);
    }
    const n = bufs[0].length;
    const out = Buffer.alloc(n);
    for (let i = 0; i + 1 < n; i += 2) {
      let sum = 0;
      for (let k = 0; k < bufs.length; k++) {
        const b = bufs[k];
        if (i + 1 < b.length) sum += b.readInt16LE(i);
      }
      if (sum > 32767) sum = 32767;
      if (sum < -32768) sum = -32768;
      out.writeInt16LE(sum, i);
    }
    const b64 = out.toString('base64');
    roomSend(room, { type: 'call', action: 'group-audio', roomId: room.id, data: b64 });
  } catch (e) { /* 混音失败就跳过这一轮，别把整个房间搞崩 */ }
}
function roomClose(room) {
  if (room.timer) { clearInterval(room.timer); room.timer = null; }
  room.frames.clear();
  callRooms.delete(room.id);
}

function currentUser(req) {
  /* 令牌来源：优先 Authorization: Bearer（打包进 App 的版本用这个，跨域带不了 Cookie），
     其次才是网页版的会话 Cookie */
  const auth = String((req.headers && req.headers.authorization) || '');
  let token = null;
  if (/^bearer\s+/i.test(auth)) token = auth.replace(/^bearer\s+/i, '').trim();
  if (!token) token = parseCookies(req)[COOKIE_NAME];
  const data = verifyTokenData(token);
  if (!data) return null;
  const user = db.users.find((u) => u.id === data.sub) || null;
  if (!user) return null;
  // 会话版本对不上说明密码改过 / 在其他设备点了「退出其他设备」
  if ((data.v || 0) !== (user.tokenVersion || 0)) return null;
  /* 手机单点登录：手机令牌里的 ps 必须等于账号当前的手机会话号。
     对不上 = 这个账号已经在另一台手机上登录了 → 标个记号，
     请求层回 401 other_login，客户端弹「已在别处登录」卡片。 */
  if ((data.k || 'phone') === 'phone'
      && (Number(data.ps) || 0) !== (Number(user.phoneSession) || 0)) {
    req.__otherLogin = true;
    return null;
  }
  return user;
}

function sessionCookie(token, maxAgeSeconds) {
  return COOKIE_NAME + '=' + encodeURIComponent(token) +
    '; Path=/; HttpOnly; SameSite=Lax; Max-Age=' + maxAgeSeconds;
}

/* -------------------------------------------------------------- 关系与视图 */

const findUser = (id) => db.users.find((u) => u.id === id) || null;

function findUserByName(username) {
  const key = String(username || '').toLowerCase();
  return db.users.find((u) => u.username.toLowerCase() === key) || null;
}

function friendshipBetween(a, b) {
  return db.friendships.find((f) =>
    (f.fromId === a && f.toId === b) || (f.fromId === b && f.toId === a)) || null;
}

function friendIds(userId) {
  return db.friendships
    .filter((f) => f.status === 'accepted' && (f.fromId === userId || f.toId === userId))
    .map((f) => (f.fromId === userId ? f.toId : f.fromId));
}

/* 意见反馈：一行一条 JSONL（data/feedback.jsonl）。
   微信那套字段：分类 / 描述 / 截图（最多 4 张）/ 联系方式 / 状态 / 官方回复。 */
const FEEDBACK_FILE = path.join(DATA_DIR, 'feedback.jsonl');
function readFeedbackRows() {
  try {
    return fs.readFileSync(FEEDBACK_FILE, 'utf8').split('\n')
      .map((s) => s.trim()).filter(Boolean)
      .map((line) => { try { return JSON.parse(line); } catch (err) { return null; } })
      .filter(Boolean);
  } catch (err) { return []; }
}
function writeFeedbackRows(rows) {
  try {
    fs.writeFileSync(FEEDBACK_FILE, rows.map((r) => JSON.stringify(r)).join('\n') + (rows.length ? '\n' : ''), 'utf8');
    return true;
  } catch (err) { return false; }
}

/* 建一个一对一会话（机器人 / 代发消息 / 欢迎语都用它） */
function createDirectChat(aId, bId) {
  const chat = {
    id: uid('c'), type: 'direct', name: '', avatar: '',
    memberIds: [aId, bId], ownerId: aId, seq: 0, createdAt: now()
  };
  db.chats.push(chat);
  saveChats();
  return chat;
}

/* ============================================================
   系统通知号（照微信的「微信团队」）
   · 账号叫「星言团队」，固定 id u_faf7c87fbaf3af67（原来那个空壳号，改名复用）
   · sysNotice(用户id, 文本, 标题?) → 在它俩的会话里落一条消息
   ============================================================ */
const SYS_ACCOUNT_ID = 'u_faf7c87fbaf3af67';
/* ---------- 官方号（星言团队 / 星联世界 …）的名字和头像 ----------
   data/official.json：{ "team": {"name":"星言团队","avatar":"/uploads/xxx.png"} }
   key：team = 系统通知号；其余就是机器人的 username（qqnews / ai / housekeeper / kefu） */
const OFFICIAL_FILE = 'official.json';
const OFFICIAL_KEYS = ['team', 'qqnews', 'ai', 'housekeeper', 'kefu'];
function readOfficial() {
  const j = readJson(path.join(DATA_DIR, OFFICIAL_FILE), null);
  return (j && typeof j === 'object') ? j : {};
}
function saveOfficial(j) { writeJson(path.join(DATA_DIR, OFFICIAL_FILE), j || {}); }
function officialOf(key) {
  const o = readOfficial();
  const v = o[String(key || '')];
  return (v && typeof v === 'object') ? v : {};
}
/** 管理页要展示的官方号清单（名字 / 头像 / 说明） */
function officialList() {
  const out = [];
  const sys = findUser(SYS_ACCOUNT_ID) || sysAccount();
  if (sys) {
    out.push({ key: 'team', name: sys.nickname || '星言团队', avatar: sys.avatar || '',
      desc: '系统通知（登录 / 安全 / 支付 / 公告）', sys: true });
  }
  ['qqnews', 'ai', 'housekeeper', 'kefu'].forEach((un) => {
    const b = findBot(un);
    if (!b) return;
    out.push({ key: un, name: b.nickname || un, avatar: b.avatar || '', desc: b.bio || '', sys: false });
  });
  return out;
}
/** 把覆盖值套到真账号上（会话列表 / 名片立刻变） */
function applyOfficial(key) {
  const ov = officialOf(key);
  if (key === 'team') { const u = sysAccount(); return u; }
  const b = findBot(key);
  if (!b) return null;
  let ch = false;
  if (ov.name && b.nickname !== ov.name) { b.nickname = ov.name; ch = true; }
  if (ov.avatar !== undefined && b.avatar !== (ov.avatar || '')) { b.avatar = ov.avatar || ''; ch = true; }
  if (ch) saveUsers();
  return b;
}

function sysAccount() {
  const u = findUser(SYS_ACCOUNT_ID);
  if (!u) return null;
  const ov = officialOf('team');
  const wantName = (ov.name && String(ov.name).trim()) || '星言团队';
  const wantAvatar = (ov.avatar !== undefined) ? String(ov.avatar || '') : null;
  let ch = false;
  if (u.nickname !== wantName) { u.nickname = wantName; ch = true; }
  if (wantAvatar !== null && u.avatar !== wantAvatar) { u.avatar = wantAvatar; ch = true; }
  if (!u.bio) { u.bio = '账号安全 / 支付 / 公告通知'; ch = true; }
  if (ch) saveUsers();
  return u;
}
/** 给某个用户发一条系统通知（失败不影响主流程） */
/* ---------- 通知开关（后台/管理页能管控） ----------
   data/sysnotice.json：
   { "enabled": 1, "types": { "login":1, "security":1, "pay":1, "notice":1 },
     "texts": { "login": "…", "security": "…", "pay": "…", "notice": "…" } }
   关掉某一类，那类就不发了；文案里可以用 {user} {time} {device} {amount} 占位。 */
const SYS_NOTICE_FILE = 'sysnotice.json';
const SYS_NOTICE_DEFAULT = {
  enabled: 1,
  types: { login: 1, security: 1, pay: 1, notice: 1 },
  texts: {}
};
function readSysNoticeCfg() {
  const j = readJson(path.join(DATA_DIR, SYS_NOTICE_FILE), null);
  if (!j || typeof j !== 'object') return JSON.parse(JSON.stringify(SYS_NOTICE_DEFAULT));
  const out = JSON.parse(JSON.stringify(SYS_NOTICE_DEFAULT));
  out.enabled = j.enabled === 0 ? 0 : 1;
  if (j.types && typeof j.types === 'object') {
    Object.keys(out.types).forEach((k) => { out.types[k] = (j.types[k] === 0) ? 0 : 1; });
  }
  if (j.texts && typeof j.texts === 'object') {
    Object.keys(j.texts).forEach((k) => { if (j.texts[k]) out.texts[k] = String(j.texts[k]).slice(0, 500); });
  }
  return out;
}
function saveSysNoticeCfg(j) { writeJson(path.join(DATA_DIR, SYS_NOTICE_FILE), j); }

/** 给某个用户发一条系统通知（失败不影响主流程）
    type: login / security / pay / notice —— 对应后台那几个开关 */
function sysNotice(userId, text, title, type) {
  try {
    const cfg = readSysNoticeCfg();
    if (!cfg.enabled) return;
    const kind = String(type || 'notice');
    if (cfg.types[kind] === 0) return;
    const sys = sysAccount();
    if (!sys || !userId || userId === sys.id) return;
    if (!findUser(userId)) return;
    const chat = directChatBetween(sys.id, userId);
    if (!chat) return;
    const t = String(title || '').trim();
    const body = String(text || '');
    if (!t && !body) return;
    deliverMessage(sys, chat.id, 'sysnotice',
      JSON.stringify({ title: t || '通知', text: body, at: Date.now() }), '');
    callTrace('系统通知 → ' + userId + '：' + body.slice(0, 40));
  } catch (e) {
    callTrace('系统通知失败：' + (e && e.message ? e.message : e));
  }
}

function directChatBetween(a, b) {
  // 自己和自己（名片里的「发消息」）：必须两边都是自己，否则会误匹配到别人的单聊
  if (a === b) {
    return db.chats.find((c) =>
      c.type === 'direct' && c.memberIds.length === 2 && c.memberIds.every((id) => id === a)) || null;
  }
  return db.chats.find((c) =>
    c.type === 'direct' && c.memberIds.length === 2 &&
    c.memberIds.includes(a) && c.memberIds.includes(b)) || null;
}

/* 通过好友以后用：给这两个人开一个会话（已有就直接用），返回那个会话。
   —— 新加的好友会立刻出现在「微信」首页，不用等谁先发第一条消息。 */
function openChatForFriendship(aId, bId) {
  const exist = directChatBetween(aId, bId);
  if (exist) return exist;
  return createDirectChat(aId, bId);
}

// 删掉会话只是「对我隐藏」，对方那边不受影响；来了新消息会自动回到列表
const chatsOf = (userId) => db.chats.filter((c) => {
  if (!c.memberIds.includes(userId)) return false;
  if ((c.hiddenFor || []).includes(userId)) return false;
  /* 「在线客服」不占会话列表：它有独立的客服页面（聊天记录还在，客服页照常收发） */
  if (c.type === 'direct') {
    const peerId = c.memberIds.find((id) => id !== userId);
    const peer = peerId ? findUser(peerId) : null;
    /* ⚠ 公众号也算 service（为了不被"给所有人建会话"的循环抓走），
       但它们**必须**出现在会话列表里（订阅了就该看到）——所以这里排除掉。 */
    if (peer && peer.service && !peer.oaId && !peer.oaDigest) return false;
  }
  return true;
});

function lastReadSeq(userId, chatId) {
  const per = db.reads[userId];
  return (per && per[chatId]) || 0;
}

function unreadCount(userId, chat) {
  const last = lastReadSeq(userId, chat.id);
  const n = loadMessages(chat.id).filter((m) => m.seq > last && m.senderId !== userId && !m.recalled).length;
  if (n > 0) return n;
  /* 左滑「标为未读」：最后一条是自己发的也算未读（微信就是这样，只显示一个小红点） */
  return (chat.flaggedUnread || []).includes(userId) ? 1 : 0;
}

/* 会话列表里「最后一条消息」的预览文字。
   用户要求：转账不显示在会话列表（每个人名字下面），那里只显示真正的会话消息，
   所以最后一条是转账时，往前找最近一条非转账消息来显示。 */
function previewTextOf(m) {
  /* 系统通知（星言团队）那种卡片：会话列表那行显示「标题 正文」，别把 JSON 漏出去 */
  if (m && m.kind === 'sysnotice') {
    try {
      const o = JSON.parse(m.content || '{}');
      const t = String(o.title || '').trim();
      const b = String(o.text || '').trim();
      return (t ? t + ' ' : '') + b;
    } catch (e) { return '通知'; }
  }
  if (!m) return '';
  if (m.recalled) return '[消息已撤回]';
  /* 会话列表里非文字消息统一显示成 [xx]（和微信一致） */
  switch (m.kind) {
    /* 引用别人的消息：微信的会话列表写着「[引用] 正文」 */
    case 'text': return (m.quote ? '[引用] ' : '') + String(m.content).slice(0, 40);
    /* 笔记卡片：会话列表里写「[笔记] 标题」（微信也是这样） */
    case 'note': {
      const first = String(m.content || '').split('\n')[0] || '';
      const t = first.indexOf('[图]') === 0 ? '图片' : first;
      return '[笔记] ' + t.slice(0, 30);
    }
    case 'image': return '[图片]';
    /* 一次发多张（九宫格）：微信列表里也是「[图片]」 */
    case 'images': return '[图片]';
    /* 公众号文章：会话列表里显示 [文章] 标题（微信就是这样） */
    case 'oa': {
      try { const o = JSON.parse(String(m.content || '{}')); return '[文章] ' + String(o.title || '').slice(0, 30); }
      catch (err) { return '[文章]'; }
    }
    case 'video': return '[视频]';
    case 'file': {
      // 视频文件按微信显示成 [视频]，其它文件显示 [文件]
      let name = '';
      try { const o = JSON.parse(String(m.content || '{}')); name = String(o.name || o.url || ''); } catch (err) { name = String(m.content || ''); }
      return /\.(mp4|mov|m4v|avi|mkv|webm|3gp|flv|wmv)(\?|$)/i.test(name) ? '[视频]' : '[文件]';
    }
    case 'audio': return '[语音]';
    case 'video': return '[视频]';
    case 'livephoto': return '[实况]';
    case 'link': {
      try { const o = JSON.parse(String(m.content || '{}')); return '[' + String(o.title || '链接') + ']'; } catch (err) { return '[链接]'; }
    }
    case 'voicecall':
    case 'call': return '[语音通话]';
    case 'videocall': return '[视频通话]';
    /* 通话记录（系统消息）：微信在会话列表里直接写「通话时长 00:12」/「已取消」/「对方无应答」，
       以前这里没这一支，最后一条是通话记录时列表里显示的是「[system]」——用户说看不到通话记录就是这个 */
    case 'system': return callRecordTextOf(String(m.content || '')).slice(0, 40);
    /* 拍一拍：会话列表里微信显示的就是「拍了拍」 */
    case 'pat': return '拍了拍';
    case 'transfer': return '[转账]';
    case 'gift': return '[礼物]' + (giftNameOf(m.content) ? ' ' + giftNameOf(m.content) : '');
    case 'location': return '[位置]';
    /* 名片：会话列表里显示「[名片] 名字」（微信就是这样） */
    case 'card': {
      try { const o = JSON.parse(String(m.content || '{}')); return '[名片] ' + String(o.name || ''); } catch (err) { return '[名片]'; }
    }
    default: return '[' + m.kind + ']';
  }
}

/** 通话记录文案统一成微信那样「通话时长 00:15」：
    老记录里写的是「通话结束 · 时长 0:15」「视频通话结束 · 时长 0:15」，会话列表预览也要跟着统一 */
function callRecordTextOf(text) {
  let t = String(text || '');
  t = t.replace(/^视频通话结束\s*[·・]?\s*时长\s*/, '通话时长 ');
  t = t.replace(/^通话结束\s*[·・]?\s*时长\s*/, '通话时长 ');
  t = t.replace(/^视频通话时长\s*/, '通话时长 ');
  const mm = t.match(/^通话时长\s+(\d{1,2}):(\d{2})$/);
  if (mm) t = '通话时长 ' + ('0' + mm[1]).slice(-2) + ':' + mm[2];
  return t;
}

function lastPreviewMessage(messages) {
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    if (isLegacyTransferText(messages[i])) continue;   // 只跳过早期版本那条「💰 转账」文本
    return messages[i];
  }
  return null;
}

/* 早期版本把「转账」写成了普通文本（💰 转账 ¥xx / 💰 已发起一笔转账），
   这些历史垃圾不进会话列表预览；真正的转账消息（kind=transfer）现在正常显示成 [转账]。
   用户要求：会话列表里 图片 / 语音通话 / 文件 / 视频 / 转账 都按 [xx] 显示。 */
function isLegacyTransferText(m) {
  if (!m || m.kind !== 'text') return false;
  const c = String(m.content || '').trim();
  return c.indexOf('💰 转账') === 0 || c.indexOf('💰 已发起一笔转账') === 0;
}

function chatSummary(chat, forUserId, lastHint) {
  /* 发消息时调用方知道刚写进去的那条，就不用把整个聊天记录读一遍了
     —— 这是压测里最热的一段（每发一条消息要读 2 次聊天文件）。 */
  let last = lastHint || null;
  let previewSrc = lastHint || null;
  if (!lastHint) {
    const messages = loadMessages(chat.id);
    last = messages.length ? messages[messages.length - 1] : null;
    previewSrc = lastPreviewMessage(messages);
  }
  let title = chat.name;
  let avatar = chat.avatar || '';
  /* 会话列表里要能显示好友的「状态」小图标（微信就是这样：头像右下角挂一个 emoji） */
  let moodIcon = '';
  let moodText = '';
  if (chat.type === 'direct') {
    const otherId = chat.memberIds.find((id) => id !== forUserId) || chat.memberIds[0];
    const other = findUser(otherId);
    title = other ? displayNameFor(forUserId, other) : '未知用户';
    avatar = other ? other.avatar : '';
    if (other && moodAlive(other)) {
      moodIcon = other.moodIcon || '';
      moodText = other.moodCaption || other.moodLabel || other.moodText || '';
    }
  }
  let botRank = 9;
  /* 单聊对方是哪个机器人账号（客户端拿它判断「这一页是不是星联世界」） */
  let botName = '';
  /* 这条会话对面是不是公众号（客户端据此决定：点进去是「公众号页面」而不是聊天页） */
  let oaId = '';
  let oaDigest = false;
  /* 是不是「星言团队」那条系统通知会话（客户端拿它做微信团队那套菜单） */
  const sysTeam = (chat.type === 'direct') ? (() => {
    const o = findUser(chat.memberIds.find((id) => id !== forUserId) || '');
    return !!(o && o.id === SYS_ACCOUNT_ID);
  })() : false;
  if (chat.type === 'direct') {
    const other = findUser(chat.memberIds.find((id) => id !== forUserId) || '');
    /* 「在线客服」虽然是机器人账号，但会话按时间排，不跟着上面三个机器人置顶 */
    if (other && other.bot && other.username !== 'kefu') {
      botRank = other.username === 'housekeeper' ? 0 : (other.username === AI_USERNAME ? 1 : 2);   // 贾维斯第一 → AI 助手 → 星联世界
    }
    if (other && other.bot) botName = other.username;
    if (other && other.oaId) oaId = other.oaId;
    if (other && other.oaDigest) oaDigest = true;
  }
  /* 会话列表里昵称旁边挂等级图标（QQ 那套；单聊看对方的等级） */
  let qqLevel = 0;
  if (chat.type === 'direct') {
    const otherId = chat.memberIds.find((id) => id !== forUserId) || '';
    qqLevel = qqLevelFor(otherId);
  }
  /* 会话列表里挂会员徽章：**只挂单聊**（看对方的）。
     群聊那一行不挂 —— 以前挂的是「群主」的徽章，看着就像"挂错人了"。 */
  let memberInfo = {};
  if (chat.type === 'direct') {
    const otherId = chat.memberIds.find((id) => id !== forUserId) || '';
    memberInfo = memberFields(otherId);
  }
  /* 会话列表里那一行预览：群聊里别人发的消息，微信会写成「谁：内容」 */
  let preview = previewSrc ? previewTextOf(previewSrc) : '';
  if (previewSrc && previewSrc.recalled) {
    /* 撤回：微信在会话列表里写一整句，不是「[消息已撤回]」 */
    if (previewSrc.senderId === forUserId) preview = '你撤回了一条消息';
    else if (chat.type === 'group') {
      const who = groupNameFor(chat, forUserId, findUser(previewSrc.senderId));
      preview = (who ? who + ' ' : '') + '撤回了一条消息';
    } else preview = '对方撤回了一条消息';
  } else if (chat.type === 'group' && previewSrc && previewSrc.senderId && previewSrc.senderId !== forUserId) {
    const who = groupNameFor(chat, forUserId, findUser(previewSrc.senderId));
    if (who && preview) preview = who + '：' + preview;
  }
  /* 有人 @ 我而且我还没点进这个会话：列表那一行前面挂「[有人@我]」。
     微信就是这么个规矩 —— 不是只看最后一条，而是「没读过就一直挂着」，
     点进会话（客户端报 read）才消失。 */
  let mentionMe = false;
  if (chat.type === 'group') {
    const rows = loadMessages(chat.id);
    const readSeq = (((db.reads || {})[forUserId]) || {})[chat.id] || 0;
    for (let i = rows.length - 1; i >= 0 && i >= rows.length - 40; i--) {
      const m = rows[i];
      if (Number(m.seq || 0) <= readSeq) break;
      if (m.senderId !== forUserId && Array.isArray(m.mentions) && m.mentions.indexOf(forUserId) >= 0) {
        mentionMe = true;
        break;
      }
    }
  }
  if (mentionMe && preview) preview = '[有人@我] ' + preview;
  return {
    id: chat.id,
    type: chat.type,
    title,
    avatar,
    moodIcon,
    moodText,
    /* 只有真的是机器人（AI 助手/管家/星联世界）才给 botRank；
       普通会话给 null —— 老版本 App 是拿「botRank == nil」判断「这是不是机器人」的，
       以前这里一律给 9，导致点好友头像弹出「官方账号」名片（机器人才该弹这个）。 */
    botRank: botRank < 9 ? botRank : null,
    bot: sysTeam ? 'team' : botName,
    sysTeam: sysTeam,
    oaId: oaId,
    oaDigest: oaDigest,
    qqLevel,
    ...memberInfo,
    memberIds: chat.memberIds,
    memberCount: chat.memberIds.length,
    lastMessage: last ? {
      id: last.id,
      senderId: (previewSrc || last).senderId,
      senderName: displayNameFor(forUserId, findUser((previewSrc || last).senderId)),
      kind: (previewSrc || last).kind,
      preview,
      mentionMe,
      /* 时间是最后一条消息的时间（不受转账预览被跳过的影响） */
      createdAt: last.createdAt
    } : null,
    unread: unreadCount(forUserId, chat),
    pinned: (chat.pinnedFor || []).includes(forUserId),
    /* 消息免打扰（群屏蔽）：列表里显示小铃铛划掉，红点不弹 */
    muted: (chat.mutedFor || []).includes(forUserId),
    burn: !!chat.burn,                                    // CHRIS_BURN_V1 阅后即焚开关
    /* 左滑标为未读：微信里这种只点一个小红点、不给数字（进会话就消掉） */
    flagged: (chat.flaggedUnread || []).includes(forUserId),
    ownerId: chat.ownerId || '',
    announce: chat.type === 'group' ? (chat.announce || '') : '',
    /* 群禁言：全员禁言 / 我有没有被单独禁言 */
    muteAll: chat.type === 'group' ? !!chat.muteAll : false,
    meMuted: chat.type === 'group' ? (chat.muteMembers || []).includes(forUserId) : false,
    updatedAt: last ? last.createdAt : chat.createdAt
  };
}

/* ---------------------------------------------------------------- 朋友圈 */

function momentAudience(authorId) {
  return Array.from(new Set([authorId].concat(friendIds(authorId))));
}

/** 朋友圈图片尺寸（内存缓存，key = 图片路径，value = [w, h]）
    —— 请求里只查这里，绝不在请求里读盘：以前在 visibleMoment 里同步读文件，
       把事件循环卡住过（朋友圈发不出去/不显示就是这么来的）。 */
const __momentSizeCache = new Map();
let __momentSizeWarming = false;

/** 同步读一张图的宽高（只在后台预热时用，复用上传校验那套 imageSizeOf） */
function readImageSizeOnce(imgRef) {
  try {
    const rel = String(imgRef || '').replace(/^https?:\/\/[^/]+/, '');
    const name = rel.indexOf('/uploads/') === 0 ? rel.slice(1) : rel;
    const uploadsDir = path.join(DATA_DIR, 'uploads');
    const file = path.join(DATA_DIR, name);
    if (file.indexOf(uploadsDir) !== 0) return null;
    const lower = name.toLowerCase();
    const mime = lower.endsWith('.png') ? 'image/png'
      : lower.endsWith('.gif') ? 'image/gif'
      : lower.endsWith('.webp') ? 'image/webp'
      : lower.endsWith('.bmp') ? 'image/bmp'
      : 'image/jpeg';
    const fd = fs.openSync(file, 'r');
    const buf = Buffer.alloc(32768);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    fs.closeSync(fd);
    const sz = imageSizeOf(buf.slice(0, n), mime);
    return (sz && sz.w > 0 && sz.h > 0) ? [sz.w, sz.h] : null;
  } catch (err) { return null; }
}

/** 后台预热：把已发表动态里的图片尺寸算好放缓存。**分批 + setImmediate**，
    每批最多 10 张，中间让出事件循环 —— 不影响正在处理的请求。 */
function warmMomentSizes() {
  if (__momentSizeWarming) return;
  __momentSizeWarming = true;
  let list = [];
  try {
    const raw = fs.readFileSync(path.join(DATA_DIR, 'moments.json'), 'utf8');
    const parsed = JSON.parse(raw);
    list = Array.isArray(parsed) ? parsed : (parsed.moments || []);
  } catch (err) { list = []; }
  const refs = [];
  list.forEach((m) => {
    (m.images || []).forEach((one) => {
      const key = String(one || '');
      if (key && !__momentSizeCache.has(key) && refs.indexOf(key) < 0) refs.push(key);
    });
  });
  let i = 0;
  const step = () => {
    const end = Math.min(refs.length, i + 10);
    for (; i < end; i += 1) {
      const one = refs[i];
      __momentSizeCache.set(one, readImageSizeOnce(one));
    }
    if (i < refs.length) { setImmediate(step); return; }
    __momentSizeWarming = false;
    console.log('[朋友圈] 图片尺寸预热完成，共', __momentSizeCache.size, '张');
  };
  setImmediate(step);
}
function visibleMoment(m, viewerId) {
  /* ⚠ 2026-10-11 晚（照微信朋友圈的逻辑补齐）：**点赞和评论只对"共同好友"可见**。
     除了作者本人和我自己，别人的赞/评论只有在"我和作者互为好友、而且这个人和作者也是好友"
     （＝共同好友）时才给我看。以前是原样全给 —— 不是共同好友的人也能看到别人在这条下面的
     赞和评论，和微信不一致。 */
  const __mineFriends = new Set(friendIds(viewerId));
  const __authorFriends = new Set(friendIds(m.authorId));
  const __canSeeInteract = (uid) => uid === viewerId || uid === m.authorId
    || (__mineFriends.has(uid) && __authorFriends.has(uid));
  return {
    id: m.id,
    authorId: m.authorId,
    author: memberProfile(findUser(m.authorId), viewerId),
    content: m.content,
    images: m.images || [],
    /* 每张图的宽高：客户端据此一上来就按真实比例画框（没有这一项就会「跳一下」）。
       发表时带的尺寸覆盖新图；老图靠启动后台预热带进来的缓存 —— 这里只查内存，不读盘。 */
    imageSizes: (function () {
      const out = Object.assign({}, m.imageSizes || {});
      (m.images || []).forEach((one) => {
        if (!out[one]) {
          const sz = __momentSizeCache.get(String(one));
          if (sz) out[one] = sz;
        }
      });
      return out;
    })(),
    /* 朋友圈视频：一条动态要么九张图、要么一条视频（和微信一样） */
    video: m.video || '',
    videoCover: m.videoCover || '',
    videoSeconds: m.videoSeconds || 0,
    videoW: m.videoW || 0,
    videoH: m.videoH || 0,
    location: m.location || '',
    pinned: m.pinned === true,
    createdAt: m.createdAt,
    likes: (m.likes || []).filter((l) => __canSeeInteract(l.userId)).map((l) => ({
      userId: l.userId,
      nickname: displayNameFor(viewerId, findUser(l.userId)),
      at: l.at
    })),
    likedByMe: (m.likes || []).some((l) => l.userId === viewerId),
    comments: (m.comments || []).filter((c) => __canSeeInteract(c.userId)).map((c) => ({
      id: c.id,
      userId: c.userId,
      nickname: displayNameFor(viewerId, findUser(c.userId)),
      replyToName: c.replyTo ? displayNameFor(viewerId, findUser(c.replyTo)) : '',
      content: c.content,
      at: c.at
    })),
    mine: m.authorId === viewerId
  };
}

/* 有多少人加我、我还没处理（「新的朋友」/通讯录上那个红点数字） */
function pendingFriendRequests(userId) {
  let n = 0;
  for (let i = 0; i < db.friendships.length; i += 1) {
    const f = db.friendships[i];
    if (f.toId === userId && f.status === 'pending') n += 1;
  }
  return n;
}

function momentUnread(userId) {
  const last = db.momentViews[userId] || '';
  /* 这里以前是 friends.includes(...) —— 一千个好友 × 几千条动态就是几百万次比较，
     每个请求都要算一遍，CPU 会被打满（朋友圈一多就「崩」就是这个原因）。
     换成 Set 之后是 O(1) 查找。 */
  const mine = new Set(friendIds(userId));
  let n = 0;
  for (let i = 0; i < db.moments.length; i++) {
    const m = db.moments[i];
    if (m.authorId !== userId && mine.has(m.authorId) && String(m.createdAt) > String(last)) n++;
  }
  return n;
}

function broadcastMoment(authorId, payload) {
  momentAudience(authorId).forEach((id) => {
    if (!connections.has(id)) return;          // 离线的人本来也收不到，别再花 CPU 算未读数
    const body = Object.assign({}, payload);
    if (payload.type === 'moment' && payload.action === 'new') {
      body.unread = momentUnread(id);
    }
    sendTo(id, body);
  });
}

/* ---------------------------------------------- 朋友圈「消息列表」（微信那个小信封）
   微信：朋友圈右上角一个信封图标，点开是「谁赞了我、谁评论了我」一条条列着，
   有未读时图标上带红点。这里就是那套后端 —— 别人动我的动态时记一条，
   自己动自己的动态不记（微信也不给自己发通知）。 */

function momentNoticeUnread(userId) {
  const last = db.momentNoticeSeen[userId] || '';
  let n = 0;
  for (let i = db.momentNotices.length - 1; i >= 0; i -= 1) {
    const r = db.momentNotices[i];
    if (r.toUserId !== userId) continue;
    if (String(r.at) > String(last)) n += 1;
  }
  return n;
}

/* 一条通知长什么样：发给谁看的决定名字/头像（备注优先），动态只带一句摘要 + 第一张缩略图 */
function publicMomentNotice(row, viewerId) {
  const from = findUser(row.fromUserId);
  const u = publicUser(from) || {};
  const m = db.moments.find((x) => x.id === row.momentId);
  let thumb = '';
  if (m && Array.isArray(m.images) && m.images.length) thumb = String(m.images[0] || '');
  const preview = m ? String(m.content || '').slice(0, 60) : '';
  return {
    id: row.id,
    kind: row.kind,                       // like / comment / reply
    at: row.at,
    momentId: row.momentId,
    commentId: row.commentId || '',
    text: row.text || '',
    preview,
    thumb,
    userId: row.fromUserId,
    name: row.fromUserId === viewerId ? '我' : displayNameFor(viewerId, from),
    avatar: u.avatarPath || u.avatar || '',
    deleted: !m
  };
}

function pushMomentNotice(toUserId, fromUserId, kind, momentId, text, extra) {
  if (!toUserId || !fromUserId || toUserId === fromUserId) return;
  const row = {
    id: uid('mn'),
    toUserId,
    fromUserId,
    kind,
    momentId,
    commentId: (extra && extra.commentId) || '',
    text: String(text || '').slice(0, 120),
    at: now()
  };
  db.momentNotices.push(row);
  /* 只留最近 2000 条（和落盘保持一致，别让内存里越攒越多） */
  if (db.momentNotices.length > 2000) db.momentNotices.splice(0, db.momentNotices.length - 2000);
  saveMomentNotices();
  /* 对方在线就立刻推一条（连未读数一起带上），离线就等他下次进来拉 */
  sendTo(toUserId, {
    type: 'moment-notice',
    notice: publicMomentNotice(row, toUserId),
    unread: momentNoticeUnread(toUserId)
  });
}

/* --------------------------------------------------------------- 实时连接 */

const connections = new Map();
/* 每个账号最近一次连上来的出口 IP：通话前用来判断「两端是不是同一个网络」，
   同一个网络就直连（快、不占服务器带宽），不同网络才强制走中继。 */
const userIps = new Map();

/* 名片这种"卡片消息"是后加的：老版本客户端不认识，会把整段 JSON 当正文显示
   （用户看到的一串乱码就是这么来的）。所以按这条连接自己的版本降级：
   版本号低于 CARD_MIN_BUILD 的连接，直接收到一句纯文本。 */
const CARD_MIN_BUILD = 0;   // 临时：先把名片降级成文字，验证是不是名片渲染崩的   /* 包号从 B1 重排过：原来写 767，结果所有新版全被判成"老版本"，名片一律被降级成「[名片] 名字」—— 用户报的「名片推出去还是名字」就是这个 */   /* 名片渲染是 B767 那版上的（原来写 778，白让 767~777 那几个版本看不到名片） */
function cardFallbackName(content) {
  try { return String(JSON.parse(String(content || '{}')).name || ''); } catch (err) { return ''; }
}
function degradedForBuild(payload, build) {
  if (build >= CARD_MIN_BUILD) return payload;
  if (!payload || payload.type !== 'message' || !payload.message) return payload;
  const m = payload.message;
  if (m.kind !== 'card') return payload;
  const name = cardFallbackName(m.content);
  const msg = Object.assign({}, m, {
    kind: 'text',
    content: name ? ('[名片] ' + name) : '[名片]'
  });
  return Object.assign({}, payload, { message: msg });
}
function buildOfSocket(socket) {
  const raw = String((socket && socket.__appBuild) || '');
  const m = raw.match(/B(\d+)/);
  return m ? Number(m[1]) : 0;
}
function sendTo(userId, payload) {
  const set = connections.get(userId);
  if (!set) return 0;
  let sent = 0;
  const cache = new Map();
  set.forEach((socket) => {
    const build = buildOfSocket(socket);
    const key = String(build);
    let text = cache.get(key);
    if (text === undefined) {
      text = applyMediaBase(signUploadsInText(JSON.stringify(degradedForBuild(payload, build))));
      cache.set(key, text);
    }
    if (ws.sendText(socket, text)) sent += 1;
  });
  return sent;
}

/** 给所有在线的人发一条（配置变更之类的全局通知） */
function sendToAll(payload) {
  const text = applyMediaBase(signUploadsInText(JSON.stringify(payload)));
  let sent = 0;
  connections.forEach((set) => {
    set.forEach((socket) => { if (ws.sendText(socket, text)) sent += 1; });
  });
  return sent;
}

function sendToChat(chat, payload, exceptUserId) {
  let sent = 0;
  chat.memberIds.forEach((id) => {
    if (exceptUserId && id === exceptUserId) return;
    sent += sendTo(id, payload);
  });
  return sent;
}

/** 某个账号当前连接的 App 版本（客户端每个请求都带 X-App-Build） */
function peerBuildOf(userId) {
  const set = connections.get(userId);
  if (!set) return '';
  let out = '';
  set.forEach((s) => { if (!out && s.__appBuild) out = s.__appBuild; });
  return out;
}

function onlineUserIds() {
  const out = [];
  connections.forEach((set, userId) => {
    const who = findUser(userId);
    if (who && who.banned) return;      // 被禁用的人不算在线
    let alive = false;
    set.forEach((s) => { if (!s.destroyed) alive = true; });
    if (alive) out.push(userId);
  });
  return out;
}

function statusOf(userId) {
  const u = findUser(userId);
  return (u && u.status) || 'online';
}

/** 隐身对别人显示成离线 */
function visibleStatus(userId) {
  const st = statusOf(userId);
  return st === 'invisible' ? 'offline' : st;
}

function statusMap() {
  const out = {};
  onlineUserIds().forEach((id) => { out[id] = visibleStatus(id); });
  return out;
}

/* 只给「自己的好友」发在线名单：
   几万人在线时，如果每条连接都塞一份全量名单（1.6 万人在线时那一包就 800KB），
   服务器会被自己的推送压死。前端也只是拿它标记好友在不在线。 */
function onlineFriendsOf(userId) {
  return friendIds(userId).filter((id) => connections.has(id));
}
function friendStatusMap(userId) {
  const out = {};
  onlineFriendsOf(userId).forEach((id) => { out[id] = visibleStatus(id); });
  return out;
}

function notifyPresence(userId, online) {
  const payload = { type: 'presence', userId, online, status: online ? visibleStatus(userId) : 'offline' };
  friendIds(userId).forEach((fid) => sendTo(fid, payload));
}

/* ============================================================
   离线推送（苹果 APNs）
   规则和微信一样：**只有手机当前没连着实时通道**（App 在后台 / 被杀掉 / 没网）
   才推系统通知；连着的时候走长连接就够了，不再弹一条重复的通知。
   配置在 data/push.json：填上苹果开发者后台的 APNs 密钥（.p8 + Key ID + Team ID）
   并打开开关，推送才真的发出去；没配就是"只记日志"，不影响其它功能。
   ============================================================ */
const PUSH_FILE = path.join(DATA_DIR, 'push.json');
let pushCache = null;

function readPush() {
  if (pushCache) return pushCache;
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(PUSH_FILE, 'utf8')); } catch (e) { raw = {}; }
  const cfg = Object.assign({
    enabled: false,
    bundleId: 'com.chris.chatnative',
    teamId: '',
    keyId: '',
    keyPath: '',
    keyText: '',
    sandbox: false,
    onMessage: true,
    onFriend: true,
    onCall: true
  }, raw.config || {});
  pushCache = { config: cfg, tokens: raw.tokens && typeof raw.tokens === 'object' ? raw.tokens : {} };
  return pushCache;
}

function savePush() {
  if (!pushCache) return;
  try { writeJson(PUSH_FILE, pushCache); } catch (e) { /* 磁盘满之类的先放过 */ }
}

/** 推送是不是真的能发（密钥/团队号/开关都齐了） */
function pushReady() {
  const c = readPush().config;
  if (!c.enabled || !c.teamId || !c.keyId || !c.bundleId) return false;
  if (!c.keyText && !c.keyPath) return false;
  if (c.keyPath && !fs.existsSync(c.keyPath)) return false;
  return true;
}

/** 某个人现在有没有活着的实时连接（有就不推系统通知） */
function isUserConnected(userId) {
  const set = connections.get(userId);
  if (!set) return false;
  let alive = false;
  set.forEach((s) => { if (!s.destroyed) alive = true; });
  return alive;
}

/* APNs 用的是 ES256 签的 JWT；苹果要求最多 1 小时换一次，这里 50 分钟换一次 */
let jwtCache = { at: 0, token: '', key: '' };

function apnsJwt() {
  const c = readPush().config;
  const key = c.keyText || (c.keyPath ? fs.readFileSync(c.keyPath, 'utf8') : '');
  const now = Date.now();
  if (jwtCache.token && jwtCache.key === key && now - jwtCache.at < 50 * 60 * 1000) return jwtCache.token;
  const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  const head = b64({ alg: 'ES256', kid: c.keyId });
  const claims = b64({ iss: c.teamId, iat: Math.floor(now / 1000) });
  const signing = head + '.' + claims;
  /* ES256 的 JWT 签名必须是 r||s 的原始格式（不是 DER），所以要点名 ieee-p1363 */
  const sig = crypto.sign('sha256', Buffer.from(signing), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  jwtCache = { at: now, token: signing + '.' + sig, key };
  return jwtCache.token;
}

/** 真发一条 APNs 通知；返回 { ok, status, reason } */
function apnsSend(deviceToken, sandbox, payload) {
  return new Promise((resolve) => {
    const c = readPush().config;
    const host = sandbox ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
    let done = false;
    let client = null;
    const finish = (r) => {
      if (done) return;
      done = true;
      try { if (client) client.close(); } catch (e) { }
      resolve(r);
    };
    try {
      client = http2.connect(host);
    } catch (e) {
      return finish({ ok: false, status: 0, reason: String(e && e.message || e) });
    }
    client.on('error', (e) => finish({ ok: false, status: 0, reason: String(e && e.message || e) }));
    let req = null;
    try {
      req = client.request({
        ':method': 'POST',
        ':path': '/3/device/' + deviceToken,
        authorization: 'bearer ' + apnsJwt(),
        'apns-topic': c.bundleId,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-expiration': String(Math.floor(Date.now() / 1000) + 3600),
        'content-type': 'application/json'
      });
    } catch (e) {
      return finish({ ok: false, status: 0, reason: String(e && e.message || e) });
    }
    let status = 0;
    let text = '';
    req.on('response', (h) => { status = Number(h[':status']) || 0; });
    req.setEncoding('utf8');
    req.on('data', (d) => { if (text.length < 400) text += d; });
    req.on('end', () => finish({ ok: status === 200, status, reason: text }));
    req.on('error', (e) => finish({ ok: false, status: 0, reason: String(e && e.message || e) }));
    req.end(JSON.stringify(payload));
    setTimeout(() => finish({ ok: false, status: 0, reason: 'timeout' }), 8000);
  });
}

function pushRemoveToken(userId, token) {
  const p = readPush();
  if (!p.tokens[userId]) return;
  p.tokens[userId] = p.tokens[userId].filter((d) => d.token !== token);
  if (!p.tokens[userId].length) delete p.tokens[userId];
  savePush();
}

/** 记一条推送日志（只留最近 300 条，后台页面能看到发没发出去） */
function pushLog(row) {
  try {
    fs.appendFileSync(path.join(DATA_DIR, 'push-log.jsonl'), JSON.stringify(Object.assign({ at: now() }, row)) + '\n', 'utf8');
  } catch (e) { }
  try {
    const f = path.join(DATA_DIR, 'push-log.jsonl');
    const lines = fs.readFileSync(f, 'utf8').trim().split('\n');
    if (lines.length > 300) fs.writeFileSync(f, lines.slice(-300).join('\n') + '\n', 'utf8');
  } catch (e) { }
}

/** 某个人所有会话的未读总数 —— 推到手机上就是「桌面图标右上角那个数字」 */
function unreadTotalOf(userId) {
  let n = 0;
  chatsOf(userId).forEach((c) => { n += unreadCount(userId, c); });
  return n;
}

function pushPreview(kind, content) {
  if (kind === 'image') return '[图片]';
  if (kind === 'images') return '[图片]';
  if (kind === 'oa') { try { return '[文章] ' + String((JSON.parse(String(content || '{}')) || {}).title || '').slice(0, 30); } catch (e) { return '[文章]'; } }
  if (kind === 'audio') return '[语音]';
  if (kind === 'file') return '[文件]';
  if (kind === 'location') return '[位置]';
  if (kind === 'transfer') return '[转账]';
  if (kind === 'announce') {
    try { return '[群公告] ' + String(content || '').replace(/\s+/g, ' ').slice(0, 30); }
    catch (e) { return '[群公告]'; }
  }
  if (kind === 'music') {
    try { return '[音乐] ' + String((JSON.parse(String(content || '{}')) || {}).title || '').slice(0, 30); }
    catch (e) { return '[音乐]'; }
  }
  if (kind === 'redpacket') return '[红包]';
  if (kind === 'gift') return '[礼物]';
  if (kind === 'link') {
    try { return '[' + (JSON.parse(content).title || '链接') + ']'; } catch (e) { return '[链接]'; }
  }
  return str(content, 80);
}

/**
 * 给一个人推系统通知。
 * opts: { kind: 'message'|'friend'|'call', title, body, chatId, fromId, sound, badge }
 */
async function pushToUser(userId, opts) {
  if (!userId) return { sent: 0, reason: 'no-user' };
  const p = readPush();
  const c = p.config;
  if (opts.kind === 'message' && c.onMessage === false) return { sent: 0, reason: 'off' };
  if (opts.kind === 'friend' && c.onFriend === false) return { sent: 0, reason: 'off' };
  if (opts.kind === 'call' && c.onCall === false) return { sent: 0, reason: 'off' };
  if (opts.kind === 'pair' && c.onPair === false) return { sent: 0, reason: 'off' };
  if (!pushReady()) {
    pushLog({ userId, kind: opts.kind, title: opts.title, skipped: 'not-configured' });
    return { sent: 0, reason: 'not-configured' };
  }
  const devices = p.tokens[userId] || [];
  if (!devices.length) return { sent: 0, reason: 'no-device' };
  let sent = 0;
  /* 桌面图标上的红点数字：不传就按「当前未读总数」算，和微信一样 */
  const badge = typeof opts.badge === 'number' ? opts.badge : unreadTotalOf(userId);
  for (const d of devices) {
    const payload = {
      aps: Object.assign({
        alert: { title: String(opts.title || '').slice(0, 60), body: String(opts.body || '').slice(0, 160) },
        sound: opts.sound === false ? undefined : 'default',
        'thread-id': opts.chatId || opts.kind || 'chris',
        'mutable-content': 0
      }, { badge: badge }),
      /* 折叠：同一个会话连着来消息，通知只留最新一条（微信就是这个行为）。
         注意 apns-collapse-id 要放在 payload 顶层，不是 aps 里面。 */
      'apns-collapse-id': opts.collapse ? String(opts.collapse).slice(0, 64) : undefined,
      chatId: opts.chatId || '',
      fromId: opts.fromId || '',
      kind: opts.kind || '',
      /* 「登录确认」那条通知要带上 6 位码：点通知直接进确认卡片，不用手输 */
      code: opts.pairCode || opts.code || ''
    };
    const r = await apnsSend(d.token, d.env ? d.env === 'sandbox' : !!c.sandbox, payload);
    if (r.ok) sent += 1;
    const bad = r.status === 400 || r.status === 410 || /BadDeviceToken|Unregistered|DeviceTokenNotForTopic/.test(String(r.reason || ''));
    pushLog({
      userId, kind: opts.kind, title: opts.title, ok: !!r.ok, status: r.status,
      reason: String(r.reason || '').slice(0, 120), token: String(d.token || '').slice(0, 8) + '…'
    });
    if (!r.ok && bad) pushRemoveToken(userId, d.token);
  }
  return { sent, reason: 'ok' };
}

/* ---------------- 设备确认登录：给已登录的设备发「登录确认」 ----------------
   有人在新设备上点「微信登录」（或者拿已登录的手机扫了那个码），
   这个账号**其它已登录的设备**要收到一条「登录确认」：
     · 连着实时通道的：直接推一条 pair 事件（手机收到弹本地通知，点一下进确认卡片）
     · 没连的：交给苹果推送（后台配了推送密钥才真的发得出去）
   正在扫码确认的那台设备不推（它自己就开着确认卡片，推了是骚扰）。 */
const pairNotifyAt = new Map();
function notifyPairRequest(userId, code, device, exceptDeviceId) {
  try {
    if (!userId || !code) return 0;
    const key = userId + '|' + String(code);
    const t = Date.now();
    if ((pairNotifyAt.get(key) || 0) > t - 2000) return 0;   // 同一台新设备 2 秒内只提醒一次
    pairNotifyAt.set(key, t);
    if (pairNotifyAt.size > 2000) pairNotifyAt.clear();
    const dev = String(device || '新设备').slice(0, 40);
    const payload = { type: 'pair', pairCode: String(code).slice(0, 10), pairDevice: dev,
                      at: new Date().toISOString() };
    const set = connections.get(userId);
    let sent = 0;
    if (set) {
      set.forEach((socket) => {
        if (exceptDeviceId && socket.__deviceId && socket.__deviceId === exceptDeviceId) return;
        if (ws.sendText(socket, JSON.stringify(payload))) sent += 1;
      });
    }
    /* 一台都没在线就交给苹果推送（没配密钥时 pushToUser 会直接返回 not-configured） */
    pushToUser(userId, { kind: 'pair', title: '登录确认',
                         body: '「' + dev + '」请求登录你的星言账号，点这里确认',
                         pairCode: String(code).slice(0, 10), sound: true }).catch(() => { });
    return sent;
  } catch (e) { return 0; }
}

/** 一条消息落库以后：没连着实时通道的人给他推系统通知 */
/** 现在是不是在这个人的「免打扰时段」里（22:00—07:00 这种跨天也算） */
function inQuietHours(n) {
  const a = String((n && n.muteStart) || '').trim();
  const b = String((n && n.muteEnd) || '').trim();
  if (!/^\d{2}:\d{2}$/.test(a) || !/^\d{2}:\d{2}$/.test(b)) return false;
  const toMin = (s) => Number(s.slice(0, 2)) * 60 + Number(s.slice(3, 5));
  const start = toMin(a), end = toMin(b);
  if (start === end) return false;
  const now = new Date();
  const cur = now.getHours() * 60 + now.getMinutes();
  return start < end ? (cur >= start && cur < end) : (cur >= start || cur < end);
}

function pushForMessage(sender, chat, message) {
  const p = readPush().config;
  if (!p.onMessage) return;
  /* 微信那套规则：系统消息、撤回提示不推；自己发的不推；在线的（长连接活着）不推 */
  if (!message || message.kind === 'system' || message.recalled) return;
  const title = chat.type === 'group'
    ? (chat.title || '群聊')
    : (sender.nickname || sender.username || '新消息');
  const detail = chat.type === 'group'
    ? (sender.nickname || sender.username || '') + '：' + pushPreview(message.kind, message.content)
    : pushPreview(message.kind, message.content);
  /* 这条消息 @ 了谁：被 @ 的人通知里带「有人@我」（微信就是这么提示的） */
  const atList = Array.isArray(message.mentions) ? message.mentions : [];
  chat.memberIds.forEach((id) => {
    if (id === sender.id) return;
    const who = findUser(id);
    if (!who || who.bot) return;              // 机器人不用推
    if (isUserConnected(id)) return;          // 在线（连着长连接）就不推，避免重复提醒
    const n = userNotify(who);
    if (n.on === false) return;                                  // 全局「新消息通知」关了
    if ((chat.mutedFor || []).includes(id)) return;              // 这个会话开了消息免打扰
    if (inQuietHours(n)) return;                                 // 免打扰时段：不响不震也不打扰
    /* 「通知显示消息详情」关掉：只提示"你收到一条新消息"（微信就是这样） */
    const atMe = atList.indexOf(id) >= 0;
    const body = n.showDetail === false
      ? (atMe ? '有人@我' : '你收到一条新消息')
      : (atMe ? '[有人@我] ' + detail : detail);
    pushToUser(id, {
      kind: 'message', title, body, chatId: chat.id, fromId: sender.id,
      sound: n.sound !== false,
      /* 同一个会话的推送折叠成一条（微信：同一个聊天连着来消息只留最新那条） */
      collapse: chat.id
    }).catch(() => { });
  });
}

/* ============================================================
   朋友资料（微信「设置备注和标签」那套）
   每个人对每个好友可以单独设：备注名、标签、星标、朋友权限（看他朋友圈 / 只聊天）、
   拉黑。数据存在 data/friendmeta.json，按「谁设的 → 设的是谁」两层存。
   备注名是**服务器端替换显示**的：通讯录名字、会话标题、群聊里的发送者名字
   都会用备注 —— 所以老版本 App 不用装包也能看到备注生效。
   ============================================================ */
const FRIEND_META_FILE = path.join(DATA_DIR, 'friendmeta.json');
let friendMetaCache = null;

function readFriendMeta() {
  if (friendMetaCache) return friendMetaCache;
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(FRIEND_META_FILE, 'utf8')); } catch (e) { raw = {}; }
  friendMetaCache = { byOwner: (raw && typeof raw.byOwner === 'object' && raw.byOwner) ? raw.byOwner : {} };
  return friendMetaCache;
}

function saveFriendMeta() {
  if (!friendMetaCache) return;
  try { writeJson(FRIEND_META_FILE, friendMetaCache); } catch (e) { }
}

/** 我对某个人设的资料（没人设过就返回空对象） */
function metaOf(ownerId, friendId) {
  if (!ownerId || !friendId) return {};
  const m = readFriendMeta().byOwner[ownerId];
  const row = m ? m[friendId] : null;
  return row && typeof row === 'object' ? row : {};
}

function setMeta(ownerId, friendId, patch) {
  const dbm = readFriendMeta();
  if (!dbm.byOwner[ownerId]) dbm.byOwner[ownerId] = {};
  const cur = dbm.byOwner[ownerId][friendId] || {};
  const next = Object.assign({}, cur, patch);
  if (!next.remark) delete next.remark;
  if (Array.isArray(next.tags)) {
    next.tags = next.tags.map((t) => String(t).trim().slice(0, 12)).filter(Boolean).slice(0, 10);
    if (!next.tags.length) delete next.tags;
  }
  dbm.byOwner[ownerId][friendId] = next;
  saveFriendMeta();
  return next;
}

/** 显示用的名字：有备注就用备注（微信就是这样），没有就用昵称 */
function displayNameFor(ownerId, user) {
  if (!user) return '';
  const base = user.nickname || user.username || '';
  if (!ownerId) return base;
  const m = metaOf(ownerId, user.id);
  return (m.remark && String(m.remark).trim()) ? String(m.remark).trim() : base;
}

/* 群昵称（微信「设置群昵称」/「我在本群的昵称」）：存在会话对象上
   chat.aliases = { 用户id: 群昵称 }。群里显示谁，优先用群昵称，
   没有才退回「我的备注 → 昵称 → 微信号」。 */
function memberAlias(chat, userId) {
  if (!chat || !chat.aliases || !userId) return '';
  return String(chat.aliases[userId] || '').trim();
}

/** 群里显示某人的名字（群昵称优先，和微信一致） */
function groupNameFor(chat, viewerId, user) {
  if (!user) return '';
  const a = memberAlias(chat, user.id);
  return a || displayNameFor(viewerId, user);
}

/** 我有没有拉黑他（拉黑以后他发不进来消息、也看不到我的朋友圈） */
function blockedByUser(ownerId, otherId) {
  return metaOf(ownerId, otherId).block === true;
}

/** 两个人之间任何一边拉黑了，就不让单聊消息通过 */
function chatBlockedBetween(aId, bId) {
  return blockedByUser(aId, bId) || blockedByUser(bId, aId);
}

/** 他能不能看我的朋友圈：我有没有「不让他看」（这里用 block + noMoments 表示） */
function momentsHiddenFrom(ownerId, viewerId) {
  const m = metaOf(ownerId, viewerId);
  return m.block === true || m.hideMyMoments === true;
}

/* ------------------------------------------------------------ 语音通话 */

// 进行中的通话：callId -> { id, from, to, state, startedAt, timer }
const calls = new Map();

/** 设备确认登录的登录码：6 位数字、3 分钟有效、一次性 */
const pairCodes = new Map();
const PAIR_TTL_MS = 3 * 60 * 1000;
function prunePairCodes() {
  const t = Date.now();
  pairCodes.forEach((rec, code) => { if (rec.expiresAt <= t) pairCodes.delete(code); });
}
const CALL_RING_MS = 60000;   // 60 秒没人接才算未接（用户要求响久一点）

/** 注册用的图形验证码：2 分钟有效、一次性（仿 QQ 注册页那行验证码） */
const captchas = new Map();
const CAPTCHA_TTL_MS = 2 * 60 * 1000;
function pruneCaptchas() {
  const t = Date.now();
  captchas.forEach((rec, id) => { if (rec.expiresAt <= t) captchas.delete(id); });
}

/* ------------------------------------------------- 验证码（不许带明文）
   以前是把字符直接写进 SVG 的 <text> 里 —— 任何脚本一行正则就能抠出答案，
   等于没有验证码。现在用 5×7 点阵把字符画成一堆小方块，
   SVG 里只有一串坐标，没有文字，脚本要解就得自己写 OCR。
   同时每个字符单独旋转、加噪点干扰线。 */
const CAPTCHA_FONT = {
  A: [14, 17, 17, 31, 17, 17, 17], B: [30, 17, 17, 30, 17, 17, 30],
  C: [14, 17, 16, 16, 16, 17, 14], D: [30, 17, 17, 17, 17, 17, 30],
  E: [31, 16, 16, 30, 16, 16, 31], F: [31, 16, 16, 30, 16, 16, 16],
  G: [14, 17, 16, 23, 17, 17, 15], H: [17, 17, 17, 31, 17, 17, 17],
  J: [7, 2, 2, 2, 2, 18, 12], K: [17, 18, 20, 24, 20, 18, 17],
  L: [16, 16, 16, 16, 16, 16, 31], M: [17, 27, 21, 21, 17, 17, 17],
  N: [17, 25, 21, 19, 17, 17, 17], P: [30, 17, 17, 30, 16, 16, 16],
  Q: [14, 17, 17, 17, 21, 18, 13], R: [30, 17, 17, 30, 20, 18, 17],
  S: [15, 16, 16, 14, 1, 1, 30], T: [31, 4, 4, 4, 4, 4, 4],
  U: [17, 17, 17, 17, 17, 17, 14], V: [17, 17, 17, 17, 17, 10, 4],
  W: [17, 17, 17, 21, 21, 21, 10], X: [17, 17, 10, 4, 10, 17, 17],
  Y: [17, 17, 10, 4, 4, 4, 4], Z: [31, 1, 2, 4, 8, 16, 31],
  2: [14, 17, 1, 2, 4, 8, 31], 3: [31, 2, 4, 2, 1, 17, 14],
  4: [2, 6, 10, 18, 31, 2, 2], 5: [31, 16, 30, 1, 1, 17, 14],
  6: [6, 8, 16, 30, 17, 17, 14], 7: [31, 1, 2, 4, 8, 8, 8],
  8: [14, 17, 17, 14, 17, 17, 14], 9: [14, 17, 17, 15, 1, 2, 12]
};

/* ============================================================
   登录滑动验证（拖滑块拼图）
     ① 客户端 GET /api/slider 领一道题：缺口位置在服务端随机定
     ② 用户把滑块拖到缺口上，客户端把最终位置 POST /api/slider/verify
     ③ 位置对上（±容差）→ 发一张**一次性通行证**（3 分钟、用掉即废）
     ④ 登录时必须带 sliderTicket，服务端验票（且收走）才继续
   想关掉：data/security.json 里写 "sliderLogin": 0，即时生效、不用重启。
   说明：这是「挡脚本、加摩擦」的一层，不是密码学保证 ——
        缺口位置要发给客户端画图，写死的脚本照样能算出来；
        真正的后手是登录限流（10 分钟错 8 次就封）和下面这张一次性票。
   ============================================================ */
const SLIDER_W = 260;          // 坐标系（客户端按这个宽渲染）
const SLIDER_H = 130;
const SLIDER_PIECE = 44;       // 滑块 / 缺口边长
const SLIDER_TOL = 6;          // 允许差几个像素
const SLIDER_TTL_MS = 3 * 60 * 1000;
const sliderChallenges = new Map();   // id -> { x, y, exp, used, fail }
const sliderTickets = new Map();      // ticket -> { exp, used }
const sliderRate = new Map();         // ip -> { n, first }

function pruneSlider() {
  const t = Date.now();
  sliderChallenges.forEach((r, id) => { if (r.exp <= t) sliderChallenges.delete(id); });
  sliderTickets.forEach((r, k) => { if (r.exp <= t || r.used) sliderTickets.delete(k); });
  sliderRate.forEach((r, k) => { if (t - r.first > 10 * 60 * 1000) sliderRate.delete(k); });
}

/** 出题：缺口左边缘的 x、上边缘的 y 都由服务端随机定 */
function makeSliderChallenge() {
  pruneSlider();
  const pad = 8;
  const x = pad + Math.round(Math.random() * (SLIDER_W - SLIDER_PIECE - pad * 2));
  const y = pad + Math.round(Math.random() * (SLIDER_H - SLIDER_PIECE - pad * 2));
  const id = uid('sld');
  sliderChallenges.set(id, { x, y, exp: Date.now() + SLIDER_TTL_MS, used: false, fail: 0 });
  return {
    id,
    width: SLIDER_W,
    height: SLIDER_H,
    piece: SLIDER_PIECE,
    // 给客户端画图和画缺口用（缺口就在这个位置）
    targetX: x,
    targetY: y,
    tolerance: SLIDER_TOL,
    // 背景图案用这个种子生成：客户端自己不发送任何图案，只报位置
    seed: Math.floor(Math.random() * 100000),
    expiresIn: Math.round(SLIDER_TTL_MS / 1000)
  };
}

/** 校验滑块位置；对了发一张一次性通行证 */
function checkSlider(id, x, y) {
  pruneSlider();
  const rec = sliderChallenges.get(id);
  if (!rec || rec.used || rec.exp <= Date.now()) return { error: '这道题过期了，重新滑一次' };
  /* 只看横向位置：缺口和滑块都在同一条水平线上，客户端也拖不动纵向 */
  const dx = Math.abs(Number(x) - rec.x);
  if (!isFinite(dx) || dx > SLIDER_TOL) {
    rec.fail = (rec.fail || 0) + 1;
    if (rec.fail >= 5) sliderChallenges.delete(id);
    return { error: '没对上，再试一次' };
  }
  rec.used = true;
  sliderChallenges.delete(id);
  const ticket = crypto.randomBytes(24).toString('hex');
  sliderTickets.set(ticket, { exp: Date.now() + SLIDER_TTL_MS, used: false });
  return { ticket, expiresIn: Math.round(SLIDER_TTL_MS / 1000) };
}

/** 登录时验票：票只能用一次，用过 / 过期都不认 */
function consumeSliderTicket(ticket) {
  pruneSlider();
  const key = String(ticket || '');
  if (!key) return false;
  const rec = sliderTickets.get(key);
  if (!rec || rec.used || rec.exp <= Date.now()) return false;
  rec.used = true;
  sliderTickets.delete(key);
  return true;
}

/** 同一个 IP 10 分钟最多换 40 次题（防刷题脚本） */
function sliderRateAllow(ip) {
  const t = Date.now();
  const r = sliderRate.get(ip);
  if (!r || t - r.first > 10 * 60 * 1000) { sliderRate.set(ip, { n: 1, first: t }); return true; }
  r.n += 1;
  return r.n <= 40;
}

function makeCaptcha() {
  pruneCaptchas();
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let text = '';
  for (let i = 0; i < 4; i++) text += chars[Math.floor(Math.random() * chars.length)];
  const id = uid('cap');
  captchas.set(id, { text, expiresAt: Date.now() + CAPTCHA_TTL_MS });
  const colors = ['#0f7cff', '#0a5ce0', '#2fa8ff', '#1e40af'];
  let glyphs = '';
  for (let i = 0; i < text.length; i++) {
    const bits = CAPTCHA_FONT[text[i]] || CAPTCHA_FONT.A;
    const ox = 18 + i * 36, oy = 14 + Math.round((Math.random() - 0.5) * 6);
    const rot = Math.round((Math.random() - 0.5) * 34);
    const fill = colors[Math.floor(Math.random() * colors.length)];
    let px = '';
    for (let r = 0; r < 7; r++) {
      for (let c = 0; c < 5; c++) {
        if (!(bits[r] & (1 << (4 - c)))) continue;
        px += '<rect x="' + (ox + c * 5.4) + '" y="' + (oy + r * 5.4) + '" width="4.6" height="4.6" rx="1.4"/>';
      }
    }
    glyphs += '<g fill="' + fill + '" transform="rotate(' + rot + ' ' + ox + ' ' + oy + ')">' + px + '</g>';
  }
  let noise = '';
  for (let i = 0; i < 6; i++) {
    noise += '<path d="M' + Math.round(Math.random() * 156) + ' ' + Math.round(Math.random() * 62) +
      ' Q' + Math.round(Math.random() * 156) + ' ' + Math.round(Math.random() * 62) +
      ' ' + Math.round(Math.random() * 156) + ' ' + Math.round(Math.random() * 62) +
      '" stroke="rgba(15,124,255,0.35)" fill="none" stroke-width="1.4"/>';
  }
  let dots = '';
  for (let i = 0; i < 40; i++) {
    dots += '<circle cx="' + Math.round(Math.random() * 156) + '" cy="' + Math.round(Math.random() * 62) +
      '" r="1.1" fill="rgba(15,124,255,0.35)"/>';
  }
  const svg = '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="64" viewBox="0 0 160 64">' +
    '<rect width="160" height="64" rx="12" fill="#f2f6ff"/>' + noise + dots + glyphs + '</svg>';
  return { id, svg };
}

function checkCaptcha(id, answer) {
  pruneCaptchas();
  const rec = captchas.get(String(id || ''));
  if (!rec) return false;
  captchas.delete(String(id || ''));   // 一次性，用完作废
  return String(answer || '').trim().toUpperCase() === rec.text;
}

function callSend(userId, payload) { return sendTo(userId, payload); }

/** 通话结束后往两个人的会话里插一条系统消息（微信也是这么记的）。
    meta 里带通话本身的信息（音频/视频、接通没接通、时长），
    客户端拿它画电话图标和「通话时长 00:12」这种行，而不是靠猜文字。 */
function callLog(fromId, toId, text, meta) {
  const a = findUser(fromId);
  const b = findUser(toId);
  if (!a || !b) return;
  let chat = directChatBetween(fromId, toId);
  if (!chat) {
    chat = {
      id: uid('c'), type: 'direct', name: '', avatar: '',
      memberIds: [fromId, toId], ownerId: fromId, seq: 0, createdAt: now()
    };
    db.chats.push(chat);
  }
  chat.hiddenFor = (chat.hiddenFor || []).filter((id) => id !== fromId && id !== toId);
  chat.seq = (chat.seq || 0) + 1;
  const message = {
    id: uid('m'), chatId: chat.id, seq: chat.seq, senderId: 'system',
    kind: 'system', content: text, createdAt: now(), recalled: false
  };
  /* 通话记录要带上「谁打的」：客户端靠它把这条记录摆到左边还是右边（微信就是这么摆的）。
     老记录里没有 from，客户端会退回「居中一行灰字」。 */
  if (meta) message.call = Object.assign({}, meta, { from: fromId, to: toId });
  appendMessage(chat.id, message);
  saveChats();
  chat.memberIds.forEach((id) => {
    sendTo(id, { type: 'message', message, chat: chatSummary(chat, id), clientId: null });
  });
}

/** 接通后的通话时长文案：微信通话记录里就是「通话时长 00:12」这种 */
function callDuration(call) {
  const secs = Math.max(1, Math.round((Date.now() - call.startedAt) / 1000));
  const mm = Math.floor(secs / 60);
  const ss = ('0' + (secs % 60)).slice(-2);
  /* 微信里语音/视频都写「通话时长 分:秒」，靠前面那个图标区分语音还是视频 */
  return { secs: secs, text: '通话时长 ' + ('0' + mm).slice(-2) + ':' + ss };
}

/* 通话流水：谁打给谁、什么动作、最后为什么结束、对面当时在不在线。
   写在 data/call-trace.log 里，「聊天页怎么没有提示」这种问题一看就知道
   是没打出去、对面不在线，还是打了但没接。 */
function callTrace(line) {
  try {
    fs.appendFileSync(path.join(DATA_DIR, 'call-trace.log'),
      '[' + new Date().toISOString() + '] ' + line + '\n', 'utf8');
  } catch (err) { /* 记不上就算了，不能因为日志把通话弄挂 */ }
}

/* 兜底清理：客户端崩溃 / 被强杀时不会发"挂断"，服务器上这通电话就一直挂着
   （表现就是：对方永远显示"正在通话中"，而且这通也不会留下通话时长记录）。
   · 响铃中超 5 分钟 → 结束（正常 65 秒就该超时了，这是二次兜底）
   · 通话中超 8 小时 → 结束（比任何真实通话都长，不会误伤） */
setInterval(() => {
  const now = Date.now();
  Array.from(calls.values()).forEach((c) => {
    if (!c || c.state === 'ended') return;
    const since = now - (c.answeredAt || c.startedAt || now);
    if (c.state === 'ringing' && since > 5 * 60 * 1000) callEnd(c, 'timeout');
    else if (since > 8 * 60 * 60 * 1000) callEnd(c, 'timeout');
  });
}, 60 * 1000).unref();

function callEnd(call, reason, extra) {
  if (call.timer) clearTimeout(call.timer);
  /* 宽限期定时器要清掉：不然通话都结束了它还会再结束一次（日志里会出现重复的 end） */
  if (call.dcTimer) { clearTimeout(call.dcTimer); call.dcTimer = null; }
  calls.delete(call.id);
  callTrace('end ' + call.from + ' -> ' + call.to + ' reason=' + reason
    + ' media=' + (call.media || 'audio') + ' state=' + call.state
    /* 这通电话两边各发了多少帧语音：0 = 那边的麦克风没起来（听不到就是这么来的） */
    + ' 语音帧 主叫发的=' + (((call.audioSeen || {})[call.from]) || 0)
    + ' 被叫发的=' + (((call.audioSeen || {})[call.to]) || 0)
    + ' | 到达间隔 主叫最大=' + (((call.audioMaxGap || {})[call.from]) || 0) + 'ms'
    + ' 被叫最大=' + (((call.audioMaxGap || {})[call.to]) || 0) + 'ms'
    + ' 卡顿(>150ms) 主叫=' + (((call.audioBigGap || {})[call.from]) || 0)
    + ' 被叫=' + (((call.audioBigGap || {})[call.to]) || 0));
  const other = { from: call.to, to: call.from, callId: call.id, reason, media: call.media || 'audio' };
  callSend(call.from, Object.assign({ type: 'call', action: 'end' }, other, extra || {}, { peerId: call.to }));
  callSend(call.to, Object.assign({ type: 'call', action: 'end' }, other, extra || {}, { peerId: call.from }));
  const media = call.media || 'audio';
  if (reason === 'hangup' || reason === 'disconnected') {
    const t = callDuration(call);
    callLog(call.from, call.to, t.text,
      { media: media, state: 'answered', secs: t.secs });
  } else if (reason === 'rejected') {
    callLog(call.from, call.to, '对方已拒绝', { media: media, state: 'rejected' });
  } else if (reason === 'cancel') {
    callLog(call.from, call.to, '已取消', { media: media, state: 'cancelled' });
  } else if (reason === 'timeout') {
    /* 响了 45 秒没人接：微信两边都记「对方无应答」 */
    callLog(call.from, call.to, '对方无应答', { media: media, state: 'noAnswer' });
  } else if (reason === 'offline') {
    /* 对面根本没在线（App 没开 / 长连接断着）：以前这里什么都不记，
       所以用户打完一看聊天页「没有提示」。微信这种也会留一条。 */
    callLog(call.from, call.to, '对方不在线', { media: media, state: 'offline' });
  }
}

/* 每条连接每秒钟收了多少帧（防穷举/刷屏），socket 断开自动回收 */
const wsFrames = new Map();

function handleClientMessage(user, socket, raw) {
  let msg;
  try { msg = JSON.parse(raw); } catch (err) { return; }
  if (!msg || typeof msg.type !== 'string') return;

  /* 单条连接的信令频率限制：正常聊天/通话每秒撑死几十条，
     有人拿一条连接猛刷（比如穷举 callId、刷屏）就直接断开。 */
  {
    const nowMs = Date.now();
    let r = wsFrames.get(socket);
    if (!r || nowMs - r.t > 1000) { r = { t: nowMs, n: 0 }; wsFrames.set(socket, r); }
    r.n += 1;
    if (r.n > 200) {
      try { socket.destroy(); } catch (err) { }
      return;
    }
    if (wsFrames.size > 2000) wsFrames.clear();
  }

  if (msg.type === 'ping') {
    ws.sendText(socket, JSON.stringify({ type: 'pong', t: Date.now() }));
    return;
  }

  /* 投递回执：客户端收到消息就回一条 ack（带这个会话收到的最大 seq）。
     有了它，后台「消息投递日志」才能区分 未送达 / 已送达 / 已读。 */
  if (msg.type === 'ack') {
    const chat = db.chats.find((c) => c.id === msg.chatId);
    if (!chat || !chat.memberIds.includes(user.id)) return;
    const seq = Math.max(0, Math.floor(Number(msg.seq) || 0));
    if (!db.delivered[user.id]) db.delivered[user.id] = {};
    if (seq > Number(db.delivered[user.id][chat.id] || 0)) {
      db.delivered[user.id][chat.id] = seq;
      deliveredDirty = true;
    }
    return;
  }

  if (msg.type === 'typing') {
    const chat = db.chats.find((c) => c.id === msg.chatId);
    if (!chat || !chat.memberIds.includes(user.id)) return;
    sendToChat(chat, {
      type: 'typing', chatId: chat.id, userId: user.id, nickname: user.nickname, at: Date.now()
    }, user.id);
    return;
  }

  /* 拍一拍（双击头像）：往会话里写一条居中的灰字，微信就是「张三 拍了拍 李四」。
     存的是"客观"信息（谁拍谁 + 双方当时的显示名），客户端按"我是谁"选说法。 */
  if (msg.type === 'pat') {
    const chat = db.chats.find((c) => c.id === msg.chatId);
    if (!chat || !chat.memberIds.includes(user.id)) return;
    const target = findUser(str(msg.targetId, 40));
    if (!target || !chat.memberIds.includes(target.id)) return;
    /* 拍得太快就挡掉（微信也会提示"拍了拍太频繁"） */
    const t0 = Date.now();
    if (t0 - Number(user.lastPatAt || 0) < 1500) {
      sendTo(user.id, { type: 'toast', text: '拍一拍太频繁了，歇一下' });
      return;
    }
    user.lastPatAt = t0;
    saveUsers();
    chat.seq = (chat.seq || 0) + 1;
    const message = {
      id: uid('m'), chatId: chat.id, seq: chat.seq, senderId: user.id,
      kind: 'pat',
      content: JSON.stringify({
        from: user.id, to: target.id,
        fn: displayNameFor(user.id, user) || user.nickname || user.username,
        tn: displayNameFor(user.id, target) || target.nickname || target.username,
        /* 被拍的人设的「拍一拍」后缀（微信：我 → 个人资料 → 拍一拍 → 朋友拍了拍我的＿＿）。
           客户端按"我是谁"选说法；老客户端不认这个字段，会自然退回「X 拍了拍 Y」。 */
        tt: str(target.patText, 12)
      }),
      createdAt: now(), recalled: false
    };
    appendMessage(chat.id, message);
    saveChats();
    chat.memberIds.forEach((id) => {
      sendTo(id, { type: 'message', message, chat: chatSummary(chat, id), clientId: null });
    });
    /* 再单独推一条轻量事件：接收方可以立刻震一下 */
    sendToChat(chat, { type: 'pat', chatId: chat.id, userId: user.id, targetId: target.id }, user.id);
    return;
  }
  if (msg.type === 'read') {
    const chat = db.chats.find((c) => c.id === msg.chatId);
    if (!chat || !chat.memberIds.includes(user.id)) return;
    const messages = loadMessages(chat.id);
    const lastSeq = messages.length ? messages[messages.length - 1].seq : 0;
    if (!db.reads[user.id]) db.reads[user.id] = {};
    db.reads[user.id][chat.id] = lastSeq;
    saveReads();
    sendToChat(chat, { type: 'read', chatId: chat.id, userId: user.id, seq: lastSeq }, user.id);
    return;
  }

  if (msg.type === 'send') {
    const result = deliverMessage(user, msg.chatId, msg.kind, msg.content, msg.clientId, msg.mentions,
      { imgW: msg.imgW, imgH: msg.imgH, quote: msg.quote });
    if (result.error) {
      ws.sendText(socket, JSON.stringify({ type: 'error', clientId: msg.clientId, error: result.error }));
    }
    return;
  }

  /* ---------------------------------------------------------- 直播信令（真视频直播）
     主播把画面推给每个观众（一路一个 WebRTC 连接），这里只做「转发」：
       hello 观众举手 → 转给主播；sig 是 offer/answer/ice → 原样转给对方；
       bye 谁走了 → 告诉另一头收摊。 */
  if (msg.type === 'live' && (msg.action === 'hello' || msg.action === 'sig' || msg.action === 'bye')) {
    const roomId = str(msg.roomId, 40);
    const to = str(msg.to, 40);
    if (!roomId || !to) return;
    /* 只允许同一个房间里的人互相发（观众↔主播） */
    const viewers = liveViewers.get(roomId);
    const inRoom = (viewers && viewers.has(user.id)) || (viewers && viewers.has(to));
    if (!inRoom) return;
    if (msg.action === 'hello') {
      liveHosts.set(roomId, user.id);          // 谁举手谁是主播（同一个房间只认一个）
      callTrace('直播 ' + user.id + ' 申请开播 room=' + roomId);
    }
    const payload = {
      type: 'live', action: msg.action, roomId: roomId,
      sigKind: str(msg.sigKind, 20), from: user.id,
      sdp: msg.sdp || null, candidate: msg.candidate || null
    };
    const delivered = sendTo(to, payload);
    if (!delivered && msg.action === 'hello') {
      /* 主播不在线：告诉观众一声 */
      sendTo(user.id, { type: 'live', action: 'hostGone', roomId: roomId });
    }
    return;
  }

  /* ---------------------------------------------------------- 语音通话信令 */
  if (msg.type === 'call') {
    const action = String(msg.action || '');
    const callId = str(msg.callId, 60);

    /* 通话排查：凡是带 SDP 的消息（invite / answer / sdp）都记一行候选摘要 ——
       网页版把候选打包在 SDP 里发，光看 ice 消息是看不到它带了什么的。 */
    if (msg.sdp && msg.sdp.sdp) {
      try {
        const s = String(msg.sdp.sdp);
        const lines = s.split('\n').filter((l) => l.indexOf('a=candidate:') === 0);
        const tcp = lines.filter((l) => /\stcp\s/.test(l)).length;
        const relay = lines.filter((l) => / typ relay/.test(l)).length;
        const host = lines.filter((l) => / typ host/.test(l)).length;
        const srflx = lines.filter((l) => / typ srflx/.test(l)).length;
        callTrace('sdp ' + (user.username || user.id) + ' ' + action + ' 候选=' + lines.length
          + ' tcp=' + tcp + ' relay=' + relay + ' srflx=' + srflx + ' host=' + host
          + (lines[0] ? ' 首条=' + lines[0].replace('a=candidate:', '').slice(0, 80) : ''));
      } catch (e) { }
    }

    /* 通话前先问一句：对端和我是不是同一个网络？
       same=true  → 客户端直连（快，不占服务器带宽）
       same=false → 客户端强制走中继（4G↔宽带这种打洞经常只通一半） */
    if (action === 'net') {
      const peer = findUser(str(msg.peerId, 40));
      const mine = userIps.get(user.id) || '';
      const his = peer ? (userIps.get(peer.id) || '') : '';
      const same = !!his && !!mine && his === mine;
      ws.sendText(socket, JSON.stringify({ type: 'call', action: 'net', peerId: peer ? peer.id : '', same }));
      callTrace('net ' + user.id + ' (' + mine + ') vs ' + (peer ? peer.id : '?') + ' (' + his + ') same=' + same);
      return;
    }
    if (!callId) return;

    if (action === 'invite') {
      const target = findUser(str(msg.toUserId, 40));
      if (!target) return ws.sendText(socket, JSON.stringify({ type: 'call-error', callId, error: '用户不存在' }));
      if (target.id === user.id) return ws.sendText(socket, JSON.stringify({ type: 'call-error', callId, error: '不能给自己打电话' }));
      if (!friendIds(user.id).includes(target.id)) {
        /* 排障用：把「谁想打给谁、两边的好友关系到底什么样」写进 call-trace，
           免得只看到用户说"明明是好友"。 */
        try {
          const rel = db.friendships.filter((f) => (f.fromId === user.id && f.toId === target.id)
            || (f.fromId === target.id && f.toId === user.id));
          callTrace('invite-rejected ' + user.id + '(' + (user.username || '') + ') -> '
            + target.id + '(' + (target.username || '') + ') 好友记录='
            + (rel.length ? rel.map((x) => x.fromId + '->' + x.toId + ':' + x.status).join(',') : '无'));
        } catch (err) { }
        return ws.sendText(socket, JSON.stringify({ type: 'call-error', callId, error: '先加为好友才能通话' }));
      }
      callTrace('invite ' + user.id + ' -> ' + target.id + ' media=' + (msg.media === 'video' ? 'video' : 'audio')
        + ' 对方在线=' + connections.has(target.id)
        + ' 主叫版本=' + (socket.__appBuild || '?')
        + ' 被叫版本=' + (peerBuildOf(target.id) || '?'));
      const busy = Array.from(calls.values()).find((c) => c.state !== 'ended' && (c.from === target.id || c.to === target.id));
      if (busy) {
        callLog(user.id, target.id, '对方忙线中', { media: msg.media === 'video' ? 'video' : 'audio', state: 'busy' });
        /* CHRIS_BUSY_AUTOREPLY_V1 忙线自动回复（用户要求「忙线自动回复」对齐微信）：
           对方正在通话中时，给他发一条自动回复，主叫这边会直接看到这句话。 */
        try {
          const chat = openChatForFriendship(user.id, target.id);   // CHRIS_BUSY_AUTOREPLY_V1
          if (chat) {
            chat.seq = (chat.seq || 0) + 1;
            const auto = {
              id: uid('m'), chatId: chat.id, seq: chat.seq, senderId: target.id, kind: 'text',
              content: '[自动回复] 我正在通话中，稍后联系你', createdAt: now(), recalled: false
            };
            appendMessage(chat.id, auto);
            saveChats();
            chat.memberIds.forEach((id) => sendTo(id, { type: 'message', message: auto, chat: chatSummary(chat, id), clientId: null }));
          }
        } catch (e) { }
        return ws.sendText(socket, JSON.stringify({ type: 'call-error', callId, error: target.nickname + ' 正在通话中' }));
      }
      const media = msg.media === 'video' ? 'video' : 'audio';
      const call = { id: callId, from: user.id, to: target.id, state: 'ringing', startedAt: Date.now(), timer: null, media };
      /* 先记住 invite 里的 SDP：对方待会儿才上线时，可以原样再送一遍 */
      call.sdp = msg.sdp || null;
      call.timer = setTimeout(() => {
        const cur = calls.get(callId);
        if (cur && cur.state === 'ringing') callEnd(cur, 'timeout');
      }, CALL_RING_MS);
      calls.set(callId, call);
      const delivered = callSend(target.id, {
        type: 'call', action: 'incoming', callId, media,
        peerId: user.id, peerName: user.nickname, peerAvatar: user.avatar || '', sdp: msg.sdp || null
      });
      if (!delivered) {
        /* 对方手机没连着（在后台 / 被杀掉）→ 推一条通知，至少让 TA 看到有人打过电话 */
        pushToUser(target.id, {
          kind: 'call',
          title: media === 'video' ? '视频通话' : '语音通话',
          body: (user.nickname || user.username || '有人') + ' 邀请你' + (media === 'video' ? '视频' : '语音') + '通话'
        }).catch(() => { });
        /* 微信那样：推送叫醒对方，但**先别挂断** —— 继续响铃 45 秒。
           对方点通知/打开 App 上线后，我们会把这次 invite 再送一遍（见 WS 连接处），就能接上；
           45 秒还没接才结束，并记一条「对方无应答」。 */
        return ws.sendText(socket, JSON.stringify({
          type: 'call', action: 'ringing', callId, media,
          peerId: target.id, peerName: target.nickname, peerAvatar: target.avatar || '',
          offline: true
        }));
      }
      ws.sendText(socket, JSON.stringify({ type: 'call', action: 'ringing', callId, media, peerId: target.id, peerName: target.nickname, peerAvatar: target.avatar || '' }));
      return;
    }

    const call = calls.get(callId);
    // 通话不存在了（对方已挂断、或这条是迟到的候选）就静默忽略：
    // 不能回 call-error，否则会把对方那边还在进行的通话状态带崩
    if (!call) return;
    /* 安全：只有这通电话的双方能操作它。
       以前只校验了 accept —— 别人只要猜到 callId，就能掐断你的通话（reject/cancel/hangup），
       或者往你的通话里塞 SDP/ICE（劫持媒体）。callId 是 "call+毫秒+4位随机"，是能撞出来的。 */
    if (call.from !== user.id && call.to !== user.id) {
      ws.sendText(socket, JSON.stringify({ type: 'call-error', callId, error: '这通电话跟你没关系' }));
      return;
    }
    const peer = call.from === user.id ? call.to : call.from;

    /* 通话状态同步（客户端 2026-10-12 新加）：
       state  = 我静音了 / 关了摄像头 → 转给对方，他那边画「对方已静音 / 已关闭摄像头」
       switch = 我在通话中切成语音或视频 → 转给对方并更新 call.media */
    if (action === 'state' || action === 'switch') {
      const peer = call.from === user.id ? findUser(call.to) : findUser(call.from);
      if (!peer) return;
      const payload = { type: 'call', action: action, callId, peerId: user.id };
      if (action === 'state') {
        payload.muted = !!msg.muted;
        payload.camOff = !!msg.camOff;
      } else {
        payload.video = !!msg.video;
        call.media = msg.video ? 'video' : 'audio';
      }
      callSend(peer, payload);
      return;
    }

    /* ==================== 群语音通话（多人） ==================== */
    if (action === 'group-start' || action === 'group-join') {
      const chatIdIn = str(msg.chatId, 60);
      const isStart = (action === 'group-start');
      let room = null;
      if (isStart) {
        if (!chatIdIn) return;
        const ch = db.chats.find((c) => c.id === chatIdIn && c.type === 'group');
        if (!ch || !ch.memberIds.includes(user.id)) return;
        const rid = groupRoomId(chatIdIn);
        room = callRooms.get(rid) || null;
        if (!room) {
          room = { id: rid, chatId: chatIdIn, hostId: user.id,
                   media: (String(msg.media || '') === 'video' ? 'video' : 'audio'),
                   members: new Map(), frames: new Map(), startedAt: Date.now(), timer: null };
          callRooms.set(rid, room);
          room.timer = setInterval(() => roomMixTick(room), 40);   // 40ms 混一次
        }
      } else {
        const rid = str(msg.roomId, 40);
        room = callRooms.get(rid) || null;
        if (!room) return;
        const ch = db.chats.find((c) => c.id === room.chatId);
        if (!ch || !ch.memberIds.includes(user.id)) return;
      }
      if (findRoomOf(user.id)) return;                 // 我已经在一个房里了
      /* 微信的规矩：一个通话最多 9 方（第 10 个人进不来）。
         这里挡住并回一句人话，客户端会把这句显示在通话页上。 */
      if (room.members.size >= 9) {
        callSend(user, { type: 'call-error', callId: callId, error: '通话人数已满（最多 9 人）' });
        return;
      }
      room.members.set(user.id, { at: Date.now(), name: user.nickname || '', avatar: user.avatar || '', muted: false });
      callTrace('群通话 ' + (isStart ? '发起' : '加入') + ' room=' + room.id + ' by ' + (user.username || user.id));
      const ch2 = db.chats.find((c) => c.id === room.chatId);
      const others = ch2 ? ch2.memberIds.filter((id) => id !== user.id && !findUser(id).bot) : [];
      if (isStart) {
        /* 发起：把群里其它人叫起来（他们那边弹群通话来电页） */
        others.forEach((uid) => {
          const u2 = findUser(uid);
          if (!u2) return;
          callSend(u2, { type: 'call', action: 'group-incoming', roomId: room.id,
                         chatId: room.chatId, media: room.media,
                         video: room.media === 'video',
                         peerId: user.id, peerName: user.nickname || '',
                         peerAvatar: user.avatar || '', roster: roomRoster(room) });
        });
      }
      /* 通知房里其它人"谁进来了" */
      roomSend(room, { type: 'call', action: 'group-joined', roomId: room.id,
                       peerId: user.id, peerName: user.nickname || '',
                       peerAvatar: user.avatar || '', roster: roomRoster(room) }, user.id);
      /* 回给本人：房间信息 + 现在房里都有谁 */
      callSend(user, { type: 'call', action: 'group-ready', roomId: room.id,
                       chatId: room.chatId, media: room.media,
                       video: room.media === 'video', hostId: room.hostId,
                       roster: roomRoster(room) });
      return;
    }

    /* CHRIS_CALL_LEVEL_V1 「谁在说话」：客户端每 ~300ms 报一次自己的音量，
       服务端收下并（最多 4 次/秒）把整屋音量广播出去 —— 界面据此给正在说话的人画光圈。 */
    if (action === 'level') {
      const room = findRoomOf(user.id);
      if (!room) return;
      const seat = room.members.get(user.id);
      if (seat) seat.level = Math.max(0, Math.min(1, Number(msg.level) || 0));
      const nowL = Date.now();
      if (!room.lastLevelAt || nowL - room.lastLevelAt > 250) {
        room.lastLevelAt = nowL;
        const levels = {};
        room.members.forEach((m, id) => { levels[id] = Math.round((m.level || 0) * 100) / 100; });
        roomSend(room, { type: 'call', action: 'levels', roomId: room.id, levels });
      }
      return;
    }

    /* CHRIS_GROUP_INVITE_V1 通话中拉人进**同一个**通话（对齐微信「邀请成员」）：
       把群成员叫进当前房间（复用 group-incoming，对方点接听就走 group-join 进同一个房）。 */
    if (action === 'group-invite') {
      const room = callRooms.get(str(msg.roomId, 40));
      if (!room) return;
      const ch = db.chats.find((c) => c.id === room.chatId);
      if (!ch || !ch.memberIds.includes(user.id)) return;
      const target = findUser(str(msg.toUserId, 40));
      if (!target || !ch.memberIds.includes(target.id)) return;
      const delivered = callSend(target, {
        type: 'call', action: 'group-incoming', roomId: room.id, chatId: room.chatId,
        media: room.media, video: room.media === 'video',
        peerId: user.id, peerName: user.nickname || '', peerAvatar: user.avatar || '',
        roster: roomRoster(room)
      });
      callTrace('群通话邀请 ' + user.id + ' → ' + target.id + ' room=' + room.id + ' 送达=' + delivered);
      if (!delivered) {
        pushToUser(target.id, {
          kind: 'call',
          title: room.media === 'video' ? '群视频通话' : '群语音通话',
          body: (user.nickname || user.username || '有人') + ' 邀请你加入通话'
        }).catch(() => { });
      }
      return;
    }

    if (action === 'group-leave') {
      const rid = str(msg.roomId, 40);
      const room = callRooms.get(rid);
      if (!room) return;
      room.members.delete(user.id);
      room.frames.delete(user.id);
      roomSend(room, { type: 'call', action: 'group-left', roomId: room.id,
                       peerId: user.id, roster: roomRoster(room) });
      if (room.members.size === 0) roomClose(room);
      return;
    }

    if (action === 'group-audio') {
      const rid = str(msg.roomId, 40);
      const room = callRooms.get(rid);
      if (!room || !room.members.has(user.id)) return;
      const data = typeof msg.data === 'string' ? msg.data : '';
      if (!data || data.length > 24000) return;
      try { room.frames.set(user.id, { at: Date.now(), buf: Buffer.from(data, 'base64') }); } catch (e) {}
      return;
    }

    if (action === 'accept') {
      if (call.to !== user.id) return;
      callTrace('accept ' + user.id + ' callId=' + callId);
      call.state = 'active';
      call.startedAt = Date.now();
      if (call.timer) { clearTimeout(call.timer); call.timer = null; }
      callSend(peer, { type: 'call', action: 'accepted', callId, media: call.media || 'audio', peerId: user.id });
      if (msg.sdp) callSend(call.from, { type: 'call', action: 'sdp', callId, peerId: user.id, sdp: msg.sdp });
      return;
    }

    if (action === 'reject') {
      if (call.to !== user.id) return;
      callTrace('reject ' + user.id + ' callId=' + callId + (msg.text ? ' 带回复' : ''));
      /* CHRIS_REJECT_REPLY_V1 拒接并回复（对齐微信「拒绝并回复」）：
         把这句话插进两人的单聊里，然后照常结束通话。 */
      try {
        const say = str(msg.text, 120).trim();
        if (say) {
          const chat = openChatForFriendship(call.from, call.to);
          if (chat) {
            chat.seq = (chat.seq || 0) + 1;
            const one = {
              id: uid('m'), chatId: chat.id, seq: chat.seq, senderId: user.id, kind: 'text',
              content: say, createdAt: now(), recalled: false
            };
            appendMessage(chat.id, one);
            saveChats();
            chat.memberIds.forEach((id) => sendTo(id, { type: 'message', message: one, chat: chatSummary(chat, id), clientId: null }));
          }
        }
      } catch (e) { }
      callEnd(call, 'rejected');
      return;
    }
    /* 客户端「响了很久没人接」自己挂断时会带 reason:'timeout'，
       这样记的是「对方无应答」而不是「已取消」（用户明确要分开） */
    if (action === 'cancel') {
      if (call.from !== user.id) return;
      callTrace('cancel ' + user.id + ' callId=' + callId + ' reason=' + (msg.reason || ''));
      callEnd(call, msg.reason === 'timeout' ? 'timeout' : 'cancel');
      return;
    }
    if (action === 'hangup') callTrace('hangup ' + user.id + ' callId=' + callId);
    if (action === 'hangup') { callEnd(call, call.state === 'active' ? 'hangup' : 'cancel'); return; }

    // 一端把摄像头降级成语音时，通知对端也切成语音界面
    if (action === 'media') {
      call.media = msg.media === 'video' ? 'video' : 'audio';
      callSend(peer, { type: 'call', action: 'media', callId, peerId: user.id, media: call.media });
      return;
    }

    // 媒体协商：offer / answer / ice 原样转发给对方
    if (action === 'sdp' || action === 'ice') {
      const payload = { type: 'call', action, callId, peerId: user.id };
      if (action === 'sdp') payload.sdp = msg.sdp;
      else payload.candidate = msg.candidate;
      callSend(peer, payload);
      return;
    }

    /* 局域网语音通话：手机采好的音频帧（base64）原样转给对方。
       只在通话真正接通后才转发，没接通 / 已挂断的一律丢掉；
       一帧限长一点，防止有人拿这个通道灌大包。 */
    if (action === 'audio') {
      /* 语音通话兜底：被叫的 App 已经在推音频帧，说明 TA 那边确实点了接听
         （老版本客户端走语音这条路时**只推帧、不发 accept**）。
         不在这里补一刀的话：通话状态会一直卡在 ringing，下面那行直接把两边
         的音频帧全部丢掉 —— 表现就是「双方界面都写着通话中，但一个字都听不见」，
         主叫那边还一直停在「正在呼叫…」。 */
      if (call.state === 'ringing' && call.to === user.id) {
        call.state = 'active';
        call.startedAt = Date.now();
        if (call.timer) { clearTimeout(call.timer); call.timer = null; }
        callTrace('被叫开始推语音帧，视为已接听 ' + callId + '（老客户端不发 accept）');
        callSend(call.from, {
          type: 'call', action: 'accepted', callId, media: call.media || 'audio', peerId: user.id
        });
      }
      if (call.state !== 'active') return;
      const data = typeof msg.data === 'string' ? msg.data : '';
      if (!data || data.length > 24000) return;      // 约 18KB 原始音频
      /* 通话排查：每边第一帧记一行，之后每 200 帧记一次（看谁没在发声音） */
      if (!call.audioSeen) call.audioSeen = {};
      /* 帧到达间隔：正常情况下 16kHz/40ms 一帧 = 每 40ms 来一帧。
         间隔突然变大 = 那边的网络抖了（TCP 一丢包就得等重传），这跟手机卡不卡无关。 */
      if (!call.audioLast) call.audioLast = {};
      if (!call.audioMaxGap) call.audioMaxGap = {};
      if (!call.audioBigGap) call.audioBigGap = {};
      const nowMs = Date.now();
      const prevMs = call.audioLast[user.id] || 0;
      if (prevMs) {
        const gap = nowMs - prevMs;
        if (gap > (call.audioMaxGap[user.id] || 0)) call.audioMaxGap[user.id] = gap;
        if (gap > 150) call.audioBigGap[user.id] = (call.audioBigGap[user.id] || 0) + 1;
      }
      call.audioLast[user.id] = nowMs;
      call.audioSeen[user.id] = (call.audioSeen[user.id] || 0) + 1;
      if (call.audioSeen[user.id] === 1 || call.audioSeen[user.id] % 200 === 0) {
        const other = findUser(call.from === user.id ? call.to : call.from);
        callTrace('audio ' + (user.username || user.id) + ' → ' + ((other && (other.username || other.id)) || '?')
          + ' 第 ' + call.audioSeen[user.id] + ' 帧');
      }
      callSend(peer, { type: 'call', action: 'audio', callId, peerId: user.id, data });
      return;
    }
    return;
  }

  if (msg.type === 'shake') {
    const chat = db.chats.find((c) => c.id === msg.chatId);
    if (!chat || !chat.memberIds.includes(user.id)) return;
    sendToChat(chat, {
      type: 'shake', chatId: chat.id, from: user.id, nickname: user.nickname
    }, user.id);
  }
}

/* ============================================================
   腾讯云 TRTC（音视频通话）
   服务端只做两件事：
     ① 存 sdkAppId + SDK 密钥（data/trtc.json，**密钥不下发给客户端**）
     ② 给客户端签一张 UserSig（官方 TLSSigAPIv2 算法），并算一个双方一致的房间号
   客户端拿到 { sdkAppId, userId, userSig, roomId } 直接进房，
   媒体走腾讯云（不依赖自己的 TURN，所以家里的 UDP 被挡也不影响通话）。
   ============================================================ */
const TRTC_FILE = path.join(DATA_DIR, 'trtc.json');
const TRTC_DEFAULT = { enabled: false, sdkAppId: 0, secretKey: '', expireSeconds: 604800 };

function readTrtcCfg() {
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(TRTC_FILE, 'utf8')) || {}; } catch (err) { raw = {}; }
  /* 老后台是配在 branding.json 的 trtc 字段里的，这里兼容一下 */
  if (!raw.sdkAppId) {
    try {
      const b = readJson(path.join(DATA_DIR, 'branding.json'), {});
      if (b && b.trtc && b.trtc.sdkAppId) raw = b.trtc;
    } catch (err) { /* 忽略 */ }
  }
  return {
    enabled: raw.enabled === true,
    sdkAppId: Number(raw.sdkAppId) || 0,
    secretKey: String(raw.secretKey || ''),
    expireSeconds: Number(raw.expireSeconds) > 0 ? Number(raw.expireSeconds) : TRTC_DEFAULT.expireSeconds,
    /* 语音走不走 TRTC 的总开关（默认走）。设成 false 就一键退回自建转发：
       客户端对语音取签名会拿到失败，自己继续用服务器转发通道，不用重装 App。 */
    voiceEnabled: raw.voiceEnabled !== false
  };
}

/* 官方的 TLSSigAPIv2：HMAC-SHA256 签一段固定格式的文本，再压进一个 JSON 里做 deflate+base64。
   注：不带 userbuf 时，签名用的文本里**只有** identifier/sdkappid/time/expire 四行
   （userbuf 那行整行都不出现；这一点和官方 tls-sig-api-v2 逐字节对齐过）。 */
function trtcUserSig(userId, expireSeconds, nowSeconds) {
  const cfg = readTrtcCfg();
  if (!cfg.sdkAppId || !cfg.secretKey) return '';
  const time = Number(nowSeconds) || Math.floor(Date.now() / 1000);
  const expire = Number(expireSeconds) > 0 ? Number(expireSeconds) : cfg.expireSeconds;
  const raw = 'TLS.identifier:' + userId + '\n'
    + 'TLS.sdkappid:' + cfg.sdkAppId + '\n'
    + 'TLS.time:' + time + '\n'
    + 'TLS.expire:' + expire + '\n';
  const sig = crypto.createHmac('sha256', cfg.secretKey).update(raw).digest('base64');
  const doc = {
    'TLS.ver': '2.0',
    'TLS.identifier': String(userId),
    'TLS.sdkappid': Number(cfg.sdkAppId),
    'TLS.time': time,
    'TLS.expire': expire,
    'TLS.sig': sig
  };
  return zlib.deflateSync(Buffer.from(JSON.stringify(doc), 'utf8'))
    .toString('base64')
    .replace(/\+/g, '*')
    .replace(/\//g, '-')
    .replace(/=/g, '_');
}

/* 房间号：TRTC 的房间号是 32 位无符号整数，这里把会话 id 稳定地映射成一个数字，
   两边用同一个会话 id 算出来的房间号一定一样。 */
function trtcRoomId(seed) {
  const s = String(seed || 'room');
  let h = 2166136261;
  for (let i = 0; i < s.length; i += 1) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  const n = (h >>> 0) % 2000000000;
  return n < 1000 ? n + 1000 : n;
}

function handleSocket(user, socket) {
  if (!connections.has(user.id)) connections.set(user.id, new Set());
  const set = connections.get(user.id);
  const first = set.size === 0;
  set.add(socket);
  if (first) notifyPresence(user.id, true);
  /* 重连回来了：把「闪断宽限期」取消掉，这一通电话继续（声音会接着传） */
  if (first) {
    calls.forEach((call) => {
      if (call.from !== user.id && call.to !== user.id) return;
      if (!call.dcTimer) return;
      clearTimeout(call.dcTimer);
      call.dcTimer = null;
      callTrace('重连回来，通话继续 ' + call.id);
    });
  }
  callTrace('ws 连上 ' + user.id + '（' + (user.nickname || user.username) + '）'
    + (socket.encrypted ? ' wss' : ' ws'));

  ws.sendText(socket, JSON.stringify({
    type: 'ready',
    user: publicUser(user),
    online: onlineFriendsOf(user.id),      // 只发好友，不发全站（见 friendStatusMap 上面的说明）
    onlineCount: connections.size,
    statuses: friendStatusMap(user.id),
    momentUnread: momentUnread(user.id),
    /* 重连时顺手把「待处理好友申请」也带上：手机在后台没收到推送，
      一回来就能把通讯录红点点亮，不用等用户去点通讯录 */
    friendRequests: pendingFriendRequests(user.id),
    /* 我这边服务器上到底还有没有一通"进行中"的电话：
       客户端重连（从后台回来/切网）时用它校对 —— 没有了就把本地的通话页收掉，
       不然会出现「对方早挂了、我这边还显示着」。 */
    callActive: Array.from(calls.values()).some((c) => c.state !== 'ended' && (c.from === user.id || c.to === user.id))
  }));

  ws.attach(socket, {
    onMessage: (text) => handleClientMessage(user, socket, text),
    onClose: () => {
      const s = connections.get(user.id);
      if (!s) return;
      s.delete(socket);
      if (s.size === 0) {
        connections.delete(user.id);
        callTrace('ws 断开 ' + user.id + '（' + (user.nickname || user.username) + '）');
        notifyPresence(user.id, false);
        /* 长连接偶尔会闪断（切 4G/Wi-Fi、进电梯、锁屏一下）：
           以前一断就把通话直接结束 → 表现是「打着打着自动挂断 + 中间那段没声音」。
           现在给 20 秒宽限期：这期间重连回来就继续这一通电话，
           只有真的 20 秒没回来才结束（响铃中的话仍然立刻取消，免得对面一直响）。 */
        calls.forEach((call) => {
          if (call.from !== user.id && call.to !== user.id) return;
          if (call.state !== 'active') {
            callEnd(call, 'cancel');
            return;
          }
          if (call.dcTimer) return;
          callTrace('ws 闪断：通话进入 20 秒宽限期 ' + call.id);
          call.dcTimer = setTimeout(() => {
            const c = calls.get(call.id);
            if (!c) return;
            callTrace('20 秒没重连回来，通话结束 ' + c.id);
            callEnd(c, 'disconnected');
          }, 20000);
        });
      }
    }
  });
}

/* ------------------------------------------------------------------ 消息 */

function deliverMessage(user, chatId, kind, content, clientId, mentionHint, mediaExtra) {
  if (user.banned) return { error: '账号已被管理员禁用，无法发送消息' };
  const chat = db.chats.find((c) => c.id === chatId);
  if (!chat) return { error: '会话不存在' };
  if (!chat.memberIds.includes(user.id)) return { error: '你不在这个会话里' };
  /* 单聊：任何一边拉黑了，消息就不通（微信里对方看到「消息已发出，但被对方拒收了」） */
  if (chat.type === 'direct') {
    const peerId = chat.memberIds.find((id) => id !== user.id);
    if (peerId && chatBlockedBetween(user.id, peerId)) {
      return {
        error: blockedByUser(peerId, user.id)
          ? '消息已发出，但被对方拒收了'
          : '你已经把对方拉黑，先去资料页解除才能发消息'
      };
    }
  }

  /* 群禁言：全员禁言时只有群主能说话；被单独禁言的人也不能说 */
  if (chat.type === 'group') {
    const isOwner = chat.ownerId === user.id;
    if (chat.muteAll && !isOwner) return { error: '群主开启了全员禁言' };
    if (!isOwner && (chat.muteMembers || []).includes(user.id)) return { error: '你被群主禁言了' };
  }

  /* 客户端会发的类型都必须在名单里！不在名单里的会被降级成 text，
     于是气泡里就把那段 JSON 原样显示出来 —— 用户看到的"视频乱码"就是这么来的。
     2026-09-25 补：video / livephoto（视频与实况）、dice / wheel / fortune / rps（小游戏）、
     balance / company（转账卡、经营账户）。system / call 这类只由服务端自己写，不放开。 */
  /* images = 一次发多张（4 张以上合成一条九宫格消息，body 是 {"paths":[...]}） */
  const allowed = ['text', 'image', 'images', 'file', 'audio', 'gift', 'transfer', 'location', 'redpacket', 'link',
    'video', 'livephoto', 'dice', 'wheel', 'fortune', 'rps', 'balance', 'company',
    /* 2026-10-10 补：音乐卡片 / 群公告 / 名片 —— 以前不在名单里会被降级成 text，
       收端就只看到一段 JSON 或一个名字（名片那个「发出去只有一行字」也是它）。 */
    'music', 'announce', 'card', 'sticker',
    /* 2026-10-10 补：小游戏 / 小程序分享卡片（好友分享给好友那张卡） */
    'miniapp',
    /* 系统通知号（星言团队）那种卡片 */
    'sysnotice',
    /* 2026-10-13 补：收藏里的**笔记**转发到聊天（kind=note，正文就是笔记原文，
       里面 [图]路径 那几行客户端会画成图片）。以前不在名单里 → 被降级成 text，
       对面收到一大段带 [图]路径 的"代码"，用户反馈的「笔记转发过去是个代码」就是它。 */
    'note'];
  const type = allowed.includes(kind) ? kind : 'text';
  /* IM 模块的开关：管理员关了哪一类就发不出去 */
  const imBlock = imKindBlocked(type);
  if (imBlock) return { error: imBlock };
  /* 视频通话/视频：type 里没有单独的 video，用「视频通话」开关拦 call 之外的视频文件 */
  if (type === 'file' && !readIm().video && /\.(mp4|mov|m4v|avi|mkv|webm|3gp|flv|wmv)(\?|$)/i.test(String(content || ''))) {
    return { error: '视频被管理员关闭了' };
  }
  /* 单个会话里发得太快 / 文字太长 */
  if (type === 'text' && String(content || '').length > readIm().maxTextLen) {
    return { error: '文字太长了（最多 ' + readIm().maxTextLen + ' 字）' };
  }
  /* 安全：非文本消息（图片/文件/语音）存的只是 /uploads 路径和少量参数，
     以前允许 200 万字符，客户端一发就能把聊天记录文件撑爆，现在压到 8000。 */
  let body = str(content, type === 'text' ? 4000 : 8000);
  /* 图片消息里塞的必须是本站图片 / 很小的 data:image，外链和脚本一律不收 */
  if (type === 'image') {
    const v = safeImageRef(body);
    if (v === null) return { error: '图片地址不合法' };
    body = v;
  }
  /* 链接卡片（AI 发的「点外卖 / 买东西」）：只收自家格式，网址必须是 http(s) */
  if (type === 'link') {
    let o = null;
    try { o = JSON.parse(body); } catch (e) { }
    if (!o || typeof o.url !== 'string' || !/^https?:\/\//.test(o.url)) return { error: '链接不合法' };
    body = JSON.stringify({
      title: String(o.title || '').slice(0, 40),
      sub: String(o.sub || '').slice(0, 80),
      url: o.url.slice(0, 500),
      scheme: String(o.scheme || '').slice(0, 300),
      /* 卡片缩略图：只收本站上传的图或 http(s) 地址（微信的链接卡片也是带图的） */
      image: (() => {
        const img = String(o.image || '').slice(0, 500);
        if (/^https?:\/\//i.test(img)) return img;
        if (/^\/uploads\/[A-Za-z0-9._-]+$/.test(img)) return img;
        return '';
      })(),
      /* 景点卡那种几行（人气榜 / 评价数 / 团购价） */
      meta: String(o.meta || '').slice(0, 40),
      reviews: String(o.reviews || '').slice(0, 40),
      prices: Array.isArray(o.prices) ? o.prices.slice(0, 3).map((p) => ({
        price: String((p && p.price) || '').slice(0, 12),
        off: String((p && p.off) || '').slice(0, 12),
        tag: String((p && p.tag) || '').slice(0, 40)
      })) : []
    });
  }
  if (!body) return { error: '消息内容为空' };

  /* 网关层敏感词过滤：命中直接拦下来，并记一条违规告警给审核员 */
  if (type === 'text') {
    const hit = sensitiveHit(body);
    if (hit) {
      recordViolation(user, chat, body, hit);
      return { error: '消息包含敏感词「' + hit + '」，已被拦截' };
    }
  }
  /* 分享链接（卡片那种）：链接本身也要过一遍 —— 卡片里的网址不发出去更安全 */
  if (type === 'link') {
    let href = String(body || '');
    try { href = String((JSON.parse(String(body)) || {}).url || href); } catch (e) { }
    const hit = sensitiveHit(href);
    if (hit) {
      recordViolation(user, chat, href, hit);
      return { error: '这个链接（' + hit + '）不能发' };
    }
  }

  /* @ 某人（微信群里那种「有人@我」）：默认信客户端带上的 userId 列表；
     老客户端不带这个字段，就在正文里按成员显示名扫一遍兜底 ——
     两条路合起来，不管哪个版本发的消息，被 @ 的人都能收到提示。
     @所有人 只有群主能用（微信的规矩）。 */
  let mentionIds = [];
  if (chat.type === 'group' && type === 'text') {
    const want = Array.isArray(mentionHint)
      ? mentionHint.map((x) => String(x || '')).filter(Boolean).slice(0, 200)
      : [];
    chat.memberIds.forEach((id) => {
      if (id === user.id) return;
      if (want.indexOf(id) >= 0) { mentionIds.push(id); return; }
      const other = findUser(id);
      if (!other) return;
      /* 备注名 / 昵称 / 微信号，三种写法都认 */
      /* 群昵称 / 备注名 / 昵称 / 微信号，几种写法都认 */
      const names = [memberAlias(chat, id), displayNameFor(user.id, other), other.nickname, other.username]
        .filter((n) => n && String(n).trim());
      if (names.some((n) => body.indexOf('@' + String(n).trim()) >= 0)) mentionIds.push(id);
    });
    if (body.indexOf('@所有人') >= 0 && chat.ownerId === user.id) {
      chat.memberIds.forEach((id) => {
        if (id !== user.id && mentionIds.indexOf(id) < 0) mentionIds.push(id);
      });
    }
  }

  chat.seq = (chat.seq || 0) + 1;
  // 有新消息就把「已删除会话」的隐藏标记清掉，会话重新出现在双方列表里
  if (Array.isArray(chat.hiddenFor) && chat.hiddenFor.length) chat.hiddenFor = [];
  const message = {
    id: uid('m'),
    chatId: chat.id,
    seq: chat.seq,
    senderId: user.id,
    kind: type,
    content: body,
    createdAt: now(),
    recalled: false
  };
  /* CHRIS_BURN_V1 阅后即焚：这个会话开着就标上，读一次之后服务端会把它清掉 */
  if (chat.burn) {
    message.burn = true;
    burnWatch.add(chat.id);          // 让服务端定时器盯着这个会话（不依赖客户端来扫）
    /* CHRIS_BURN_LOG_V1：便于排查「阅后即焚没生效」 */
    try { callTrace('burn 发出 ' + chat.id + ' kind=' + type + ' by ' + (user.nickname || user.username)); } catch (e) { }
  }
  /* 这条消息 @ 了谁：存下来，收消息的人靠它显示「有人@我」，也是老客户端的高亮依据 */
  if (mentionIds.length) message.mentions = mentionIds;
  /* 客户端给的这条本地 id：离线重发时靠它去重（同一 clientId 只落一条） */
  if (clientId) message.clientId = String(clientId).slice(0, 60);
  /* 图片宽高（骨架落位）：发送端带上来的优先；没带（老客户端 / 服务端自己发的图）
     就从文件头读一次补上。收/发双方第一帧就按真实比例把气泡画好，行高不再变。 */
  if (type === 'image') {
    let w = Math.round(Number(mediaExtra && mediaExtra.imgW) || 0);
    let h = Math.round(Number(mediaExtra && mediaExtra.imgH) || 0);
    if (!(w > 1 && h > 1)) {
      const d = imageDimsOf(message.content);
      if (d) { w = d.w; h = d.h; }
    }
    if (w > 1 && h > 1 && w <= 30000 && h <= 30000) { message.imgW = w; message.imgH = h; }
  }
  /* 引用卡片（微信那种结构化引用）：正文里不再拼「「谁：摘要」」，
     改成一整包挂在消息上 —— 客户端才能画成带缩略图、点一下跳原消息的引用条。
     只收 {id, who, kind, text, thumb}，长度全卡死；缩略图只认本站 /uploads 或 http(s)。 */
  try {
    const qh = mediaExtra && mediaExtra.quote;
    if (qh && typeof qh === 'object') {
      const qid = str(qh.id, 40);
      /* 引用的那条必须真在这个会话里 —— 不然就是编出来的引用，直接不收 */
      const src = qid ? loadMessages(chat.id).find((m) => m.id === qid) : null;
      if (src) {
        const thumbRaw = String(qh.thumb || '').slice(0, 500);
        const quote = {
          id: qid,
          who: str(qh.who, 40),
          kind: str(qh.kind, 12) || 'text',
          text: str(qh.text, 200),
          thumb: /^https?:\/\//i.test(thumbRaw) ? thumbRaw
            : (/^\/uploads\/[A-Za-z0-9._-]+$/.test(thumbRaw) ? thumbRaw : '')
        };
        /* 引用的是一条图片：客户端没带缩略图就用原图地址顶上 */
        if (src.kind === 'image' && !quote.thumb) quote.thumb = String(src.content || '');
        if (!quote.text && src.kind !== 'image') quote.text = '[' + String(src.kind || 'text') + ']';
        message.quote = quote;
      }
    }
  } catch (e) { /* 引用这一包有问题就当没引用，绝不能把消息本身发不出去 */ }
  appendMessage(chat.id, message);
  noteMessage();
  /* 落盘改成「攒一下再写」：以前每发一条消息都要重写整个 chats.json（1.5MB），
     压测时这是最大的瓶颈。现在最多 1.5 秒写一次，进程退出前再补一次。 */
  chatsDirty = true;

  if (!db.reads[user.id]) db.reads[user.id] = {};
  db.reads[user.id][chat.id] = message.seq;
  readsDirty = true;

  // 每个接收者的未读数不同，所以摘要要按人各算一份
  chat.memberIds.forEach((id) => {
    /* 群里显示的名字用群昵称（微信就是这样）：收消息的人立刻就该看到改过的群昵称 */
    const out = chat.type === 'group'
      ? Object.assign({}, message, { senderName: groupNameFor(chat, id, user) })
      : message;
    sendTo(id, {
      type: 'message',
      message: out,
      chat: chatSummary(chat, id, message),
      clientId: id === user.id ? (clientId || null) : null
    });
  });
  /* 手机没连着（在后台 / 被杀掉 / 没网）→ 给他推一条系统通知，微信也是这个逻辑 */
  try { pushForMessage(user, chat, message); } catch (e) { }
  /* 发给「AI 助手 / 管家」→ 机器人自动回一句（异步，不卡发送方） */
  const bot = botInChat(chat, user.id);
  if (bot && bot.username === 'kefu') {
    /* 客服：人工在后台「客服中心」回。没人在的时候先按知识库自动答一轮 */
    const sc = readSupport();
    const ac = readAiCfg();
    if (type === 'text') {
      /* 先看后台配的关键词自动回复：命中就直接回你配的文案（比 AI 更可控） */
      const hit = botInChat(chat, user.id) ? autoReplyHit(body) : '';
      if (hit) {
        try { deliverMessage(bot, chat.id, 'text', hit, null); } catch (e) { }
      }
      /* 用户说「人工 / 转人工」：不再让 AI 答，直接生成一张工单进后台，并告诉他人工会跟进 */
      /* 只要短句里提到「人工」就算要转人工（要人工 / 转人工 / 人工客服 / 找人工都算） */
      const wantHuman = !hit && body.replace(/[\s。！!?？，,.]/g, '').length <= 8
        && body.indexOf('人工') >= 0;
      if (wantHuman) {
        try {
          const ticket = {
            id: uid('tk'), userId: user.id, username: user.username || '',
            nickname: user.nickname || '', category: '转人工',
            title: '用户要求转人工',
            content: '用户在聊天里直接要求转人工（会话 ' + chat.id + '）',
            contact: '', status: 'pending', reply: '',
            createdAt: now(), repliedAt: '', doneAt: '', chatId: chat.id
          };
          appendSupportTicket(ticket);
          const tip = supportOffDuty()
            ? ('已经帮你转人工了。' + (sc.offTimeNote || '现在不在人工值班时间，你的问题已经记下来了，上班后会有人跟进。'))
            : '已经帮你转人工了。客服看到会尽快在这里回复你，也可以先把问题说清楚（比如什么时候、在哪个页面、点了什么），这样处理更快。';
          deliverMessage(bot, chat.id, 'text', tip, null);
        } catch (e) { }
      } else if (sc.autoReply && ac.apiKey && ac.enabled !== false) {
        /* 关键词命中过了就不再让 AI 答（后台配的文案优先） */
        if (!hit) {
        supportBotAnswer(user, body).then((reply) => {
          if (!reply) return;
          /* 人工下班了：AI 答完补一句「明天有人跟进」 */
          const out = supportOffDuty() ? (reply + '\n' + (sc.offTimeNote || '')) : reply;
          deliverMessage(bot, chat.id, 'text', out, null);
        }).catch((e) => { console.error('[客服] ' + ((e && e.message) || e)); });
        }
      }
    }
  } else if (bot && type === 'text') scheduleBotReply(bot, chat, user, body);
  /* 对方的自动回复开着、又不在线 → 用 AI 替他先回一句 */
  if (!bot && type === 'text') {
    const cfg = readAiCfg();
    if (cfg.enabled && cfg.autoReply && cfg.apiKey) {
      const peerId = chat.memberIds.find((id) => id !== user.id);
      const peer = peerId ? findUser(peerId) : null;
      if (peer && !peer.bot && !onlineUserIds().includes(peer.id)) scheduleAutoReply(peer, chat, user, body);
    }
  }
  return { message };
}


/* ---------------- 公众号（我们自己的，照微信那套） ----------------
   微信的公众号是两件事：① 通讯录里有一个「公众号」入口，能看关注了哪些号；
   ② 每个号在会话列表里是一条会话，发文就是给它所有粉丝各推一条图文卡片。
   这里就这么实现：
     · 关注 = 给这个号建一个「机器人账号」+ 加好友 + 开一条单聊（会话列表里就有了）
     · 发文 = 往每个粉丝的单聊里发一条 kind='oa' 的卡片消息（客户端渲染成图文卡）
   数据：data/oa.json（账号 + 文章）· data/oa-follows.json（谁关注了谁） */
const OA_FILE = 'oa.json';
const OA_FOLLOW_FILE = 'oa-follows.json';
/* ---------------- 群会议（多人视频） ----------------
   媒体走腾讯 TRTC：**房号 = 群会话 id**，同群的人进同一间房、各推各的画面，
   转发交给 TRTC（所以这里不需要像 1 对 1 那样做 offer/answer 信令）。
   服务端只做两件事：
     · 记「现在谁在房里」（data/meetings.json，重启不丢）
     · 有人进/出时给群成员推一条轻量事件（客户端据此提示、并更新群里那张加入卡片）
   结构：{ "c_xxx": { members: ["u_.."], startedAt: 毫秒, locked: false, ownerId: "" } } */
const MEETING_FILE = 'meetings.json';
function readMeetings() {
  const raw = readJson(path.join(DATA_DIR, MEETING_FILE), {});
  return raw && typeof raw === 'object' ? raw : {};
}
function saveMeetings(v) { writeJson(path.join(DATA_DIR, MEETING_FILE), v); }
/** 房间（= 群会话 id）现在的状态；没有就返回一个空的 */
function meetingOf(chatId) {
  const all = readMeetings();
  const m = all[chatId];
  return {
    members: Array.isArray(m && m.members) ? m.members : [],
    startedAt: (m && m.startedAt) || 0,
    locked: !!(m && m.locked),
    ownerId: (m && m.ownerId) || ''
  };
}
function saveMeetingOf(chatId, m) {
  const all = readMeetings();
  if (!m || (!m.members.length && !m.startedAt)) delete all[chatId];
  else all[chatId] = m;
  saveMeetings(all);
}
/* 公众号默认头像（后台新建、没填头像时用这个，风格和微信的官方号一致） */
const OA_DEFAULT_AVATAR = '/uploads/img_a89abbaaa3a47735.png';

function readOA() {
  const raw = readJson(path.join(DATA_DIR, OA_FILE), { accounts: [], articles: [] });
  return {
    accounts: Array.isArray(raw.accounts) ? raw.accounts : [],
    articles: Array.isArray(raw.articles) ? raw.articles : []
  };
}
function saveOA(v) { writeJson(path.join(DATA_DIR, OA_FILE), v); }
function readOAFollows() {
  const raw = readJson(path.join(DATA_DIR, OA_FOLLOW_FILE), { follows: [] });
  return Array.isArray(raw.follows) ? raw.follows : [];
}
function saveOAFollows(list) { writeJson(path.join(DATA_DIR, OA_FOLLOW_FILE), { follows: list }); }
function oaUsername(id) { return 'oa_' + String(id || '').replace(/[^A-Za-z0-9]/g, '').slice(0, 24); }

/** 公众号在用户列表里的那个「账号」：没有就建一个（bot），昵称/头像跟着账号配置走 */
function ensureOAUser(acc) {
  if (!acc || !acc.id) return null;
  const uname = oaUsername(acc.id);
  let u = findBot(uname);
  let changed = false;
  if (!u) {
    const salt = crypto.randomBytes(16).toString('hex');
    u = {
      id: uid('u'), username: uname, nickname: acc.name || '公众号',
      salt: salt, passwordHash: hashPassword(crypto.randomBytes(24).toString('hex'), salt),
      avatar: acc.avatar || OA_DEFAULT_AVATAR, bio: acc.bio || '', gender: 'male', region: '',
      status: 'online', tokenVersion: 0, createdAt: now(), bot: true, oaId: acc.id,
      /* ⚠ service: true 必须带上：不带的话会被"给所有人建机器人会话"的那几套循环抓走
         （每个用户都会多一个「公众号」联系人 + 一条会话）。公众号只对真正订阅的人开。 */
      service: true
    };
    db.users.push(u);
    changed = true;
  } else {
    if (u.nickname !== (acc.name || '公众号')) { u.nickname = acc.name || '公众号'; changed = true; }
    if ((u.avatar || '') !== (acc.avatar || '')) { u.avatar = acc.avatar || ''; changed = true; }
    if ((u.bio || '') !== (acc.bio || '')) { u.bio = acc.bio || ''; changed = true; }
  }
  if (changed) saveUsers();
  return u;
}

/** 「订阅号消息」这个汇总账号：所有订阅号的文章都汇总到这一条会话里（微信就是这样） */
function ensureOADigestUser() {
  const uname = 'oa_digest';
  let u = findBot(uname);
  let changed = false;
  if (!u) {
    const salt = crypto.randomBytes(16).toString('hex');
    u = {
      id: uid('u'), username: uname, nickname: '订阅号消息',
      salt: salt, passwordHash: hashPassword(crypto.randomBytes(24).toString('hex'), salt),
      avatar: '/uploads/bot-news-v2.png', bio: '你订阅的号发的文章都汇总在这里',
      gender: 'male', region: '', status: 'online', tokenVersion: 0, createdAt: now(),
      bot: true, oaDigest: true, service: true     // service: 不参与"给所有人建会话"的循环
    };
    db.users.push(u);
    changed = true;
  } else {
    if (u.oaDigest !== true) { u.oaDigest = true; changed = true; }
    if (u.service !== true) { u.service = true; changed = true; }
  }
  if (changed) saveUsers();
  return u;
}

/** 关注一个号：加好友 + 开单聊（会话列表里立刻出现） */
function oaFollow(user, acc) {
  /* 订阅号的文章汇总进「订阅号消息」那一条会话（微信就是这样），
     服务号自己单独一条会话（发重要通知那种） */
  const isSub = (acc.type || 'subscribe') === 'subscribe';
  const bot = isSub ? ensureOADigestUser() : ensureOAUser(acc);
  if (!bot) return { error: '公众号不存在' };
  const follows = readOAFollows();
  if (!follows.some((f) => f.userId === user.id && f.accountId === acc.id)) {
    follows.push({ userId: user.id, accountId: acc.id, at: now() });
    saveOAFollows(follows);
  }
  let chat = directChatBetween(user.id, bot.id);
  if (!chat) {
    const f = friendshipBetween(user.id, bot.id);
    if (!f) db.friendships.push({ id: uid('f'), fromId: bot.id, toId: user.id, status: 'accepted', createdAt: now() });
    else if (f.status !== 'accepted') f.status = 'accepted';
    saveFriendships();
    chat = createDirectChat(user.id, bot.id);
    try {
      deliverMessage(bot, chat.id, 'text', isSub
        ? '你订阅的号发的文章会汇总在这里（刚关注了「' + (acc.name || '公众号') + '」）。'
        : '你好，我是「' + (acc.name || '服务号') + '」。关注了我，以后我发的通知会出现在这里。', null);
    } catch (e) { }
  }
  /* 公众号的那条会话**固定置顶**（和 AI 助手/小星一样，一直在会话列表最上面） */
  chat.hiddenFor = (chat.hiddenFor || []).filter((id) => id !== user.id);   // 以前取消订阅藏过，重新订阅要露出来
  const pinSet = new Set(chat.pinnedFor || []);
  if (!pinSet.has(user.id)) {
    pinSet.add(user.id);
    chat.pinnedFor = Array.from(pinSet);
    saveChats();
  }
  return { chat };
}

/** 发一篇文章：给这个号的所有粉丝各推一条图文卡片；返回推送了几个人 */
function oaPublish(acc, art) {
  const isSub = (acc.type || 'subscribe') === 'subscribe';
  const body = JSON.stringify({
    accountId: acc.id, articleId: art.id, title: art.title || '',
    summary: art.summary || '', cover: art.cover || '',
    accountName: acc.name || '', accountAvatar: acc.avatar || ''
  });
  let sent = 0;
  const targets = readOAFollows()
    .filter((f) => f.accountId === acc.id)
    .map((f) => findUser(f.userId))
    .filter((u) => u && !u.bot);
  /* 一次推给很多人时**分批**做（每批 200 人，批与批之间让出事件循环），
     不然几千个粉丝的号一发文章，聊天消息就会被这一下拖住几百毫秒。 */
  const step = (i) => {
    const end = Math.min(targets.length, i + 200);
    for (let k = i; k < end; k += 1) {
      const u = targets[k];
      const bot = isSub ? ensureOADigestUser() : ensureOAUser(acc);
      let chat = bot ? directChatBetween(u.id, bot.id) : null;
      if (!chat) { oaFollow(u, acc); chat = bot ? directChatBetween(u.id, bot.id) : null; }
      if (!chat) continue;
      /* 之前取关过（会话被藏了）：重新发文就把它放回来 */
      chat.hiddenFor = (chat.hiddenFor || []).filter((id) => id !== u.id);
      try { deliverMessage(bot, chat.id, 'oa', body, null); sent += 1; } catch (e) { }
    }
    if (end < targets.length) setImmediate(() => step(end));
    else {
      saveChats();
      callTrace('公众号推送完成：' + (acc.name || '') + ' → ' + sent + ' 人');
    }
  };
  step(0);
  return targets.length;
}

/* ---------------- 新闻聚合（「星联世界」页 + AI 机器人共用） ----------------
   只接国内的源（明确不接 Google News 这类境外的）。
   手机上不直连（跨域 + 各家的防盗链），统一由这里转发；每个源各自缓存 5 分钟。
     qq      腾讯新闻热点榜（数据源还是腾讯热榜）—— 带图
     toutiao 今日头条热榜      —— 带图
     sina    新浪滚动要闻      —— 带摘要，部分带图
     weibo   微博热搜榜        —— 纯榜单，带热度值
  baidu   百度热搜榜        —— 纯榜单，带「热 / 新 / 沸」小标
   bili    哔哩哔哩热门榜     —— 带封面，点开去 B 站看原视频（精彩视频页用）
   统一结构：{ id, title, summary, source, url, img, hot, rank, tag, time } */
const NEWS_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';
const NEWS_CHANNELS = [
  { id: 'qq', label: '热点', desc: '热点榜' },
  { id: 'toutiao', label: '头条', desc: '今日头条热榜' },
  { id: 'sina', label: '要闻', desc: '新浪滚动新闻' },
  { id: 'weibo', label: '热搜', desc: '微博热搜榜' },
  { id: 'baidu', label: '百度', desc: '百度热搜榜' }
  ,
  /* 视频榜也放进来：服务端下发频道，App 划掉重开就多这一栏（不用装包）。
     以后再单独把它挪进「精彩视频」页。 */
  { id: 'bili', label: 'B站热门', desc: '哔哩哔哩热门榜（点开去 B 站看）' }
];
const NEWS_SOURCE_IDS = NEWS_CHANNELS.map(function (c) { return c.id; });
/* 精彩视频页的频道（和新闻分开：新闻是文字资讯，这里是视频榜） */
const VIDEO_CHANNELS = [
  { id: 'bili', label: 'B站热门', desc: '哔哩哔哩热门榜' }
];
const newsCache = {};                 // source -> { at, list }

function newsClean(s) { return String(s == null ? '' : s).replace(/\s+/g, ' ').trim(); }
function newsHttps(u) { u = newsClean(u); return u.indexOf('http://') === 0 ? ('https://' + u.slice(7)) : u; }
/* 我们自己 App 里显示出来的来源名，不再出现旧品牌：
   腾讯热榜里很多条本来就把来源写成「腾讯新闻」，统一显示成「星联世界」
   （别的媒体名照旧，比如「海客新闻」「环球市场播报」） */
function newsBrand(s) { return newsClean(s).replace(/腾讯新闻/g, '星联世界').replace(/腾讯网/g, '星联世界'); }
async function newsJson(url, referer) {
  const controller = new AbortController();
  const timer = setTimeout(function () { controller.abort(); }, 10000);
  try {
    const res = await fetch(url, {
      headers: { 'User-Agent': NEWS_UA, Referer: referer || '' },
      signal: controller.signal
    });
    return await res.json().catch(function () { return {}; });
  } finally { clearTimeout(timer); }
}

/* 腾讯新闻热点榜（数据源；给「星联世界」页的「热点」和 AI 机器人用） */
async function fetchQQNews(n) {
  const data = await newsJson('https://r.inews.qq.com/gw/event/hot_ranking_list?ids_hash=&offset=0&page_size=' + n, 'https://news.qq.com/');
  const raw = ((data.idlist || [])[0] || {}).newslist || [];
  return raw.map(function (it, i) {
    const t = Number(it.timestamp || 0) || 0;
    return {
      id: 'qq_' + String(it.id || i),
      title: newsClean(it.title),
      summary: newsClean(it.abstract || it.nlpAbstract),
      source: newsBrand(it.source || it.chlname) || '星联世界',
      url: newsClean(it.url || it.surl || it.short_url),
      img: newsHttps((it.thumbnails && it.thumbnails[0]) || it.fimgUrl || it.bigImage),
      hot: 0,
      rank: i + 1,
      tag: '',
      time: t ? (t < 1e12 ? t * 1000 : t) : 0      // 腾讯给的是秒
    };
  }).filter(function (x) { return x.title && !/每10分钟更新一次/.test(x.title); });
}

/* 今日头条热榜 */
async function fetchToutiaoNews(n) {
  const data = await newsJson('https://www.toutiao.com/hot-event/hot-board/?origin=toutiao_pc', 'https://www.toutiao.com/');
  const raw = (data.data || []).slice(0, n);
  return raw.map(function (it, i) {
    const cid = String(it.ClusterIdStr || it.ClusterId || i);
    return {
      id: 'tt_' + cid,
      title: newsClean(it.Title),
      summary: '',
      source: '今日头条',
      url: newsClean(it.Url) || ('https://www.toutiao.com/trending/' + cid + '/'),
      img: newsHttps(it.Image && (it.Image.url || (it.Image.url_list || [{}])[0].url)),
      hot: Number(it.HotValue || 0) || 0,
      rank: i + 1,
      tag: newsClean(it.LabelDesc).replace('热门事件', ''),
      time: 0
    };
  }).filter(function (x) { return x.title; });
}

/* 新浪滚动要闻（lid=2509 是综合要闻） */
async function fetchSinaNews(n) {
  const data = await newsJson('https://feed.mix.sina.com.cn/api/roll/get?pageid=153&lid=2509&k=&num=' + n + '&page=1', 'https://news.sina.com.cn/');
  const raw = ((data.result || {}).data) || [];
  return raw.map(function (it, i) {
    let img = '';
    const imgs = Array.isArray(it.images) ? it.images : [];
    if (imgs.length) img = imgs[0].u || imgs[0].url || '';
    if (!img && it.img && typeof it.img === 'object' && Number(it.img.w || 0) >= 200) img = it.img.u || '';
    return {
      id: 'sn_' + newsClean(it.docid || it.oid || i),
      title: newsClean(it.title),
      summary: newsClean(it.intro || it.summary || it.wapsummary),
      source: newsBrand(it.media_name) || '新浪新闻',
      url: newsHttps(it.wapurl || it.url),
      img: newsHttps(img),
      hot: 0,
      rank: i + 1,
      tag: '',
      time: (Number(it.ctime || 0) || 0) * 1000
    };
  }).filter(function (x) { return x.title && x.url; });
}

/* 微博热搜 */
async function fetchWeiboNews(n) {
  const data = await newsJson('https://weibo.com/ajax/side/hotSearch', 'https://weibo.com/');
  const raw = (((data || {}).data || {}).realtime || []).slice(0, n);
  return raw.map(function (it, i) {
    const word = newsClean(it.word_scheme || it.word);
    return {
      id: 'wb_' + newsClean(it.word || i),
      title: word.replace(/^#+|#+$/g, ''),
      summary: '',
      source: '微博热搜',
      url: 'https://m.weibo.cn/search?containerid=100103type%3D1%26q%3D' + encodeURIComponent(word),
      img: '',
      hot: Number(it.raw_hot || it.num || 0) || 0,
      rank: Number(it.realpos || 0) || (i + 1),
      tag: newsClean(it.label_name || it.icon_desc),
      time: 0
    };
  }).filter(function (x) { return x.title && x.title.length > 1; });
}

/* 百度热搜榜 */
async function fetchBaiduNews(n) {
  const data = await newsJson('https://top.baidu.com/api/board?platform=wise&tab=realtime', 'https://top.baidu.com/board');
  const items = [];
  (((data || {}).data || {}).cards || []).forEach(function (card) {
    (card.content || []).forEach(function (grp) {
      (grp.content || []).forEach(function (it) { items.push(it); });
    });
  });
  return items.slice(0, n).map(function (it, i) {
    return {
      id: 'bd_' + newsClean(it.url || i).slice(-28),
      title: newsClean(it.word),
      summary: newsClean(it.desc),
      source: '百度热搜',
      url: newsClean(it.url),
      img: '',
      hot: Number(it.hotScore || 0) || 0,
      rank: Number(it.index || 0) || (i + 1),
      tag: newsClean(it.newHotName),
      time: 0
    };
  }).filter(function (x) { return x.title; });
}

/* 哔哩哔哩热门榜：**唯一「能真拿到、也允许嵌入」的国内视频源**。
   我们只拿标题/封面/UP主/播放量做成卡片，点开去 B 站看原视频（不搬运视频本体）。
   抖音、快手网页版是纯 JS 空壳，服务端拿不到真实列表，所以不接。 */
async function fetchBiliNews(n) {
  const data = await newsJson('https://api.bilibili.com/x/web-interface/popular?ps=' + Math.min(50, n) + '&pn=1', 'https://www.bilibili.com/');
  const list = (((data || {}).data || {}).list) || [];
  return list.map(function (it, i) {
    const bv = it.bvid || ('av' + (it.aid || ''));
    const owner = (it.owner && it.owner.name) || '';
    const secs = Number(it.duration || 0) || 0;
    const mmss = secs ? (Math.floor(secs / 60) + ':' + String(secs % 60).padStart(2, '0')) : '';
    return {
      id: 'bili_' + (it.bvid || it.aid || i),
      title: newsClean(it.title),
      summary: owner + (mmss ? (' · ' + mmss) : ''),
      source: '哔哩哔哩' + (owner ? (' · ' + owner) : ''),
      url: 'https://www.bilibili.com/video/' + bv,
      img: newsHttps(it.pic || ''),
      hot: Number((it.stat && it.stat.view) || 0) || 0,
      rank: i + 1,
      tag: '',
      time: 0
    };
  }).filter(function (x) { return x.title && x.img; });
}

const NEWS_FETCHERS = { qq: fetchQQNews, toutiao: fetchToutiaoNews, sina: fetchSinaNews, weibo: fetchWeiboNews, baidu: fetchBaiduNews, bili: fetchBiliNews };

async function fetchNews(source, limit) {
  const okIds = NEWS_SOURCE_IDS.concat(VIDEO_CHANNELS.map(function (c) { return c.id; }));
  const src = okIds.indexOf(String(source)) >= 0 ? String(source) : 'qq';
  const n = Math.max(5, Math.min(50, Number(limit) || 30));
  const hit = newsCache[src];
  if (hit && hit.list.length && Date.now() - hit.at < 5 * 60 * 1000) return { source: src, list: hit.list.slice(0, n), at: hit.at };
  /* 一次就抓够（至少 40 条）：不然第一个人只请求 5 条，缓存里就只有 5 条，
     后面的人要 40 条也只能拿到 5 条 —— 5 分钟之内都是这样 */
  const want = Math.min(50, Math.max(n + 5, 40));
  let list = [];
  try {
    list = await NEWS_FETCHERS[src](want);
  } catch (e) {
    console.error('[news:' + src + '] ' + (e && e.message));
  }
  if (list && list.length) newsCache[src] = { at: Date.now(), list: list };
  const cached = newsCache[src] || { at: 0, list: [] };
  return { source: src, list: cached.list.slice(0, n), at: cached.at };
}

/* 兼容老调用（AI 机器人的新闻问答、旧客户端的 /api/news 都不带 source） */
async function fetchTencentNews(limit) {
  const r = await fetchNews('qq', limit);
  return r.list;
}

/* ==================================================================== 机器人
   两个账号：ai（AI 助手）· housekeeper（管家）
   · AI 助手：聊天问答，需要最新信息时自动联网搜索
   · 管家：提醒 / 天气 / 时间 / 记账 / 代发消息 / 发朋友圈，其它问题转给 AI
   配置在 data/ai.json（密钥、模型、人设），后台 /ai.html 也能改。 */
function readAiCfg() {
  const raw = readJson(path.join(DATA_DIR, AI_FILE), {});
  return Object.assign({}, AI_DEFAULT, raw && typeof raw === 'object' ? raw : {});
}
function saveAiCfg(patch) {
  const next = Object.assign(readAiCfg(), patch || {});
  writeJson(path.join(DATA_DIR, AI_FILE), next);
  return next;
}
function findBot(name) { return db.users.find((u) => u.username === name) || null; }
function botInChat(chat, senderId) {
  if (!chat || chat.type !== 'direct') return null;
  const bot = chat.memberIds.map(findUser).find((u) => u && u.bot);
  if (!bot || bot.id === senderId) return null;
  return bot;
}
/* 建机器人账号，并让它们成为所有人的好友 */
/* 机器人索引：ensureBots 以前对每个用户线性扫全部好友表 + 会话表
   （压测副本上量过：1694 用户 × (8774 好友 + 3 × 8537 会话) ≈ 8600 万次比较），
   启动时会把一个核吃满十几秒，随数据量平方增长。先把「好友对 / 单聊对」建成 Map，
   后面查一次 O(1)。实测副本启动从 10~20 秒降到 3 秒。 */
function BOT_PAIR_KEY(a, b) { a = String(a); b = String(b); return a < b ? (a + '|' + b) : (b + '|' + a); }
function buildBotIndexes() {
  const fr = new Map();
  db.friendships.forEach(function (f) { const k = BOT_PAIR_KEY(f.fromId, f.toId); if (!fr.has(k)) fr.set(k, f); });
  const dc = new Map();
  db.chats.forEach(function (c) {
    if (c.type === 'direct' && Array.isArray(c.memberIds) && c.memberIds.length === 2) {
      dc.set(BOT_PAIR_KEY(c.memberIds[0], c.memberIds[1]), c);
    }
  });
  return { fr: fr, dc: dc };
}
function ensureBots() {
  const IDX = buildBotIndexes();
  const bots = [
    { username: AI_USERNAME, nickname: 'AI 助手', avatar: '/uploads/bot-ai.png', bio: '有问题随时问我，还能帮你查最新资讯～' },
    { username: 'housekeeper', nickname: '小星', avatar: '/uploads/bot-housekeeper-v2.png', bio: '您的私人助理：提醒、天气、记账、代发消息，随时为您效劳' },
    { username: 'qqnews', nickname: '星联世界', avatar: '/uploads/bot-news-v2.png', bio: '热点新闻、时事资讯，想听哪条跟我说' }
  ];
  let changed = false;
  bots.forEach((cfg) => {
    let bot = findBot(cfg.username);
    if (!bot) {
      /* 机器人账号也用哈希存（以前这里直接写明文 —— 谁也没法用它登录，
         但数据库里不该出现明文密码） */
      const botSalt = crypto.randomBytes(16).toString('hex');
      bot = {
        id: uid('u'), username: cfg.username, nickname: cfg.nickname,
        salt: botSalt,
        passwordHash: hashPassword(crypto.randomBytes(24).toString('hex'), botSalt),
        avatar: cfg.avatar, bio: cfg.bio,
        gender: 'male', region: '', status: 'online', tokenVersion: 0, createdAt: now(), bot: true
      };
      db.users.push(bot);
      changed = true;
    } else {
      if (bot.bot !== true) {
        bot.bot = true;
        changed = true;
      }
      /* 昵称跟着代码走：改名字只需要改上面那行 nickname，重启一次就生效
         （不然老库里还是旧名字，用户那边的会话列表一直显示旧名） */
      if (cfg.nickname && bot.nickname !== cfg.nickname) {
        bot.nickname = cfg.nickname;
        changed = true;
        console.log('[bots] rename ' + cfg.username + ' -> ' + cfg.nickname);
      }
    }
    /* 后台 / App 管理页改过的名字、头像优先（data/official.json） */
    {
      const ov = officialOf(cfg.username);
      if (ov.name && bot.nickname !== ov.name) { bot.nickname = ov.name; changed = true; }
      if (ov.avatar !== undefined && bot.avatar !== (ov.avatar || '')) { bot.avatar = ov.avatar || ''; changed = true; }
    }
    db.users.forEach((u) => {
      if (u.id === bot.id || u.bot) return;
      const fk = BOT_PAIR_KEY(u.id, bot.id);
      const f = IDX.fr.get(fk);
      if (!f) {
        const nf = { id: uid('f'), fromId: bot.id, toId: u.id, status: 'accepted', createdAt: now() };
        db.friendships.push(nf);
        IDX.fr.set(fk, nf);
        changed = true;
      } else if (f.status !== 'accepted') {
        f.status = 'accepted';
        changed = true;
      }
    });
  });
  /* 「星言团队」那个官方号也跟着 official.json（名字 / 头像） */
  try { sysAccount(); } catch (e) {}
  if (changed) { saveUsers(); saveFriendships(); }
  /* 每个账号和机器人的会话都固定置顶（取消不了） */
  let chatChanged = false;
  db.users.forEach((u) => {
    if (u.bot) return;
    db.users.filter((b) => b.bot && !b.service).forEach((b) => {
      const chat = IDX.dc.get(BOT_PAIR_KEY(u.id, b.id));
      if (!chat) return;
      const set = new Set(chat.pinnedFor || []);
      if (!set.has(u.id)) { set.add(u.id); chat.pinnedFor = Array.from(set); chatChanged = true; }
      /* ⚠ 以前这里会把用户从 hiddenFor 里删掉（「开服自动放回来」）——
         结果用户删掉的机器人会话，服务器一重启就又冒出来（用户报的
         「有些东西删除了会自己回来」）。现在**不再动 hiddenFor**：
         删了就一直是删的，等真有新消息时由发消息那条路放回来（微信也是这个规矩）。 */
    });
  });
  if (chatChanged) saveChats();
  return findBot(AI_USERNAME);
}

/* ---------------- 大模型 ---------------- */
async function llmChat(messages, cfg) {
  const cfgNow = cfg || readAiCfg();
  if (!cfgNow.apiKey) throw new Error('还没配置 AI 密钥');
  const url = String(cfgNow.baseUrl || AI_DEFAULT.baseUrl).replace(/\/+$/, '') + '/chat/completions';
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 60000);
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + cfgNow.apiKey },
      body: JSON.stringify({
        model: cfgNow.model || AI_DEFAULT.model,
        messages,
        temperature: Number(cfgNow.temperature) || 1.1,
        max_tokens: Number(cfgNow.maxTokens) || 800,
        stream: false
      }),
      signal: controller.signal
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error((data.error && data.error.message) || ('接口返回 ' + res.status));
    const text = data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content;
    return String(text || '').trim();
  } finally { clearTimeout(timer); }
}

/* ---------------- 联网搜索（Bing，不用密钥） ---------------- */
function stripTags(s) {
  return String(s || '').replace(/<[^>]*>/g, ' ')
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/\s+/g, ' ').trim();
}
async function webSearch(q) {
  const url = 'https://cn.bing.com/search?q=' + encodeURIComponent(q) + '&setlang=zh-CN';
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 12000);
  try {
    const res = await fetch(url, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
        'Accept-Language': 'zh-CN,zh;q=0.9'
      },
      signal: controller.signal
    });
    const html = await res.text();
    const out = [];
    const re = /<li class="b_algo"[\s\S]*?<h2[^>]*>([\s\S]*?)<\/h2>([\s\S]*?)<\/li>/g;
    let m;
    while ((m = re.exec(html)) && out.length < 5) {
      const title = stripTags(m[1]);
      const body = stripTags(m[2]);
      if (title) out.push(title + ' —— ' + body.slice(0, 220));
    }
    return out;
  } catch (e) {
    return [];
  } finally { clearTimeout(timer); }
}
function needsSearch(text) {
  return /最新|今天|今日|现在|实时|新闻|股价|价格|多少钱|汇率|比分|天气|谁是|什么时候|上映|发布|开售|政策|规定|怎么样|推荐|附近|几点|几号|是哪/.test(String(text || ''));
}

/* ---------------- 天气（wttr.in，不用密钥） ---------------- */
async function getWeather(city) {
  const c = String(city || '上海').trim() || '上海';
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 12000);
  try {
    const res = await fetch('https://wttr.in/' + encodeURIComponent(c) + '?format=%l：%C %t，体感%f，湿度%h，风%w&lang=zh', {
      headers: { 'User-Agent': 'curl/8.0' },
      signal: controller.signal
    });
    let t = (await res.text()).trim();
    if (!t || t.length > 160) return '';
    const map = {
      Sunny: '晴', Clear: '晴', 'Partly cloudy': '多云', Cloudy: '多云', Overcast: '阴',
      Mist: '薄雾', Fog: '雾', Haze: '霾', 'Light rain': '小雨', 'Moderate rain': '中雨',
      'Heavy rain': '大雨', 'Light drizzle': '毛毛雨', 'Patchy rain nearby': '局部有雨',
      'Light snow': '小雪', Snow: '雪', 'Heavy snow': '大雪', Thunderstorm: '雷阵雨',
      'Patchy light rain': '零星小雨', 'Moderate or heavy rain shower': '阵雨'
    };
    Object.keys(map).forEach((k) => { t = t.split(k).join(map[k]); });
    return t;
  } catch (e) { return ''; } finally { clearTimeout(timer); }
}

/* ---------------- 提醒 ---------------- */
function remindersFile() { return path.join(DATA_DIR, 'reminders.json'); }
function loadReminders() { const d = readJson(remindersFile(), { items: [] }); return Array.isArray(d.items) ? d.items : []; }
function saveReminders(items) { writeJson(remindersFile(), { items }); }
function scheduleReminderTick() {
  setInterval(() => {
    const items = loadReminders();
    if (!items.length) return;
    const t = Date.now();
    let changed = false;
    items.forEach((r) => {
      if (r.done || r.at > t) return;
      r.done = true;
      changed = true;
      const bot = findBot('housekeeper');
      const user = findUser(r.userId);
      if (!bot || !user) return;
      let chat = directChatBetween(bot.id, user.id);
      if (!chat) chat = createDirectChat(bot.id, user.id);
      try { deliverMessage(bot, chat.id, 'text', '⏰ 提醒你：' + r.text, null); } catch (e) { }
    });
    if (changed) saveReminders(items.filter((r) => !r.done || !r.at || r.at > t - 7 * 24 * 3600 * 1000));
  }, 20000);
}

/* ---------------- 点餐 / 购物（贾维斯当店员） ---------------- */
function shopFile() { return path.join(DATA_DIR, 'shop.json'); }
function loadShop() {
  const d = readJson(shopFile(), {});
  const food = Array.isArray(d.food) && d.food.length ? d.food : [
    { name: '美式咖啡', price: 18 }, { name: '拿铁', price: 22 }, { name: '牛肉面', price: 26 },
    { name: '黄焖鸡米饭', price: 28 }, { name: '水果拼盘', price: 25 }
  ];
  const goods = Array.isArray(d.goods) && d.goods.length ? d.goods : [
    { name: '抽纸 3 包', price: 25 }, { name: '矿泉水一箱', price: 20 }, { name: '零食大礼包', price: 49 }
  ];
  return { food, goods };
}
function ordersFile() { return path.join(DATA_DIR, 'orders.json'); }
function loadOrders() { const d = readJson(ordersFile(), { items: [] }); return Array.isArray(d.items) ? d.items : []; }
function saveOrders(items) { writeJson(ordersFile(), { items }); }
function lastMenu(userId) { return (lastShopMenu.get(userId) || null); }
function money(n) { return '¥' + (Math.round(Number(n || 0) * 100) / 100).toFixed(2); }

/* ---------------- 机器人回话 ---------------- */
const lastDraft = new Map();          // userId -> 最后一条朋友圈草稿
const lastShopMenu = new Map();       // userId -> { kind, items }（刚给过的菜单/商品）
const aiTodo = new Map();             // userId -> 等用户「确认」的那件事（转账 / 建群 / 发消息）

function historyFor(chatId, botId, limit) {
  const msgs = loadMessages(chatId).filter((m) => !m.recalled && m.kind !== 'system').slice(-limit);
  return msgs.map((m) => ({
    role: m.senderId === botId ? 'assistant' : 'user',
    content: m.kind === 'text' ? String(m.content || '').slice(0, 1000)
      : m.kind === 'image' ? '（对方发了一张图片）'
        : m.kind === 'location' ? '（对方发了一个位置）'
          : ('（对方发了一条' + m.kind + '消息）')
  })).filter((m) => m.content);
}
/* 点餐/购物发图片：图是提前做好的（data/uploads/shop_*.png），这里只负责把 URL 发出去 */
async function sendShopImages(bot, chat, items, kind, max) {
  const n = Math.min(max || 6, items.length);
  for (let i = 0; i < n; i++) {
    const it = items[i];
    if (!it || !it.img) continue;
    try { deliverMessage(bot, chat.id, 'image', it.img, null); } catch (e) { }
    await new Promise((r) => setTimeout(r, 120));
  }
}

/* 帮用户找联系人：精确 → 前缀 → 包含（备注/昵称/用户名都行） */
function findContacts(user, name) {
  const kw = String(name || '').trim().toLowerCase();
  if (!kw) return [];
  const all = db.users.filter((u) => u.id !== user.id);
  let hits = all.filter((u) => (u.nickname || '').toLowerCase() === kw || (u.username || '').toLowerCase() === kw);
  if (!hits.length) hits = all.filter((u) => (u.nickname || '').toLowerCase().startsWith(kw) || (u.username || '').toLowerCase().startsWith(kw));
  if (!hits.length) hits = all.filter((u) => (u.nickname || '').toLowerCase().includes(kw) || (u.username || '').toLowerCase().includes(kw));
  return hits;
}
function openChatWith(user, target) {
  let chat = directChatBetween(user.id, target.id);
  if (!chat) chat = createDirectChat(user.id, target.id);
  const f = friendshipBetween(user.id, target.id);
  if (!f) db.friendships.push({ id: uid('f'), fromId: user.id, toId: target.id, status: 'accepted', createdAt: now() });
  else if (f.status !== 'accepted') f.status = 'accepted';
  saveFriendships();
  return chat;
}

/* 「星联世界」这个号的回答：报热点 / 讲第N条 / 其他问题用新闻+联网作答 */
async function newsBotAnswer(bot, chat, user, text) {
  const t = String(text || '').trim();
  const list = await fetchTencentNews(10);
  if (!list.length) return '这会儿取不到新闻，稍后再问我一次。';
  const map = { '一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10 };
  const m = t.match(/讲讲?第\s*(\d{1,2}|[一二三四五六七八九十])\s*条/);
  if (m) {
    const idx = (map[m[1]] || Number(m[1]) || 1) - 1;
    const it = list[idx];
    if (!it) return '没找到第 ' + (idx + 1) + ' 条，先跟我说「新闻」看看今天的列表。';
    const cfg = readAiCfg();
    const hits = await webSearch(it.title);
    const msgs = [{ role: 'system', content: '你是星联世界的新闻编辑，用三句话讲清楚这条新闻：发生了什么、为什么重要，口语一点，不要 Markdown。' },
      { role: 'user', content: it.title + (it.summary ? ('\n摘要：' + it.summary) : '') + (hits.length ? ('\n联网补充：' + hits.slice(0, 3).join('\n')) : '') }];
    const out = await llmChat(msgs, cfg);
    return (out || it.title) + '\n（来源：' + (it.source || '星联世界') + '）';
  }
  if (/^(你好|您好|在吗|hi|hello|嗨|新闻|今天的?新闻|热点|头条)/i.test(t)) {
    const d = new Date();
    const pad = (n) => ('0' + n).slice(-2);
    return '星联世界 · 热点（' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + '）：\n' +
      list.slice(0, 6).map((x, i) => (i + 1) + '. ' + x.title).join('\n') +
      '\n想看哪条细节？说「讲讲第 2 条」就行。';
  }
  /* 其它内容：只从新闻里找，不做别的回答 */
  const kw = t.replace(/[？?。，,！!、\s]/g, '');
  const hit = kw ? list.find((x) => (x.title + (x.summary || '')).indexOf(kw.slice(0, 6)) >= 0) : null;
  if (hit) {
    return '看到一条相关的：\n· ' + hit.title + '（' + (hit.source || '星联世界') + '）\n想看细节就说「讲讲第 ' +
      (list.indexOf(hit) + 1) + ' 条」。';
  }
  return '我只负责报新闻～\n发「新闻」看今天的热点，或者说「讲讲第 2 条」让我讲细一点。';
}

/* 管家的固定命令：不走大模型，快又稳 */
async function housekeeperCommand(user, text, chat, bot) {
  const t = String(text || '').trim();
  if (/^(几点|现在几点|时间|日期|今天几号)/.test(t)) {
    const d = new Date();
    const pad = (n) => ('0' + n).slice(-2);
    return '现在是 ' + d.getFullYear() + ' 年 ' + (d.getMonth() + 1) + ' 月 ' + d.getDate() + ' 日 ' +
      pad(d.getHours()) + ':' + pad(d.getMinutes()) + '（' + ['周日', '周一', '周二', '周三', '周四', '周五', '周六'][d.getDay()] + '）';
  }
  let m = t.match(/^天气\s*([\u4e00-\u9fa5]{2,10})?$/) || t.match(/^([\u4e00-\u9fa5]{2,10})的?天气$/);
  if (m) {
    const city = m[1] || user.region || '上海';
    const w = await getWeather(city);
    return w ? '🌤 ' + w : ('没查到 ' + city + ' 的天气，换个城市名试试？');
  }
  /* 提醒：支持「提醒我 8:30 开会」和「晚上 9 点提醒我吃药」两种说法 */
  m = t.match(/(?:提醒我?|叫我|记得)\s*(明天|今天|今晚)?\s*(\d{1,2})\s*[点:：]\s*(\d{1,2})?\s*分?\s*(.*)/) ||
      t.match(/(早上|上午|中午|下午|傍晚|晚上|今晚|明天|今天)?\s*(\d{1,2})\s*[点:：]\s*(\d{1,2})?\s*分?\s*(?:提醒我?|叫我|记得)\s*(.*)/);
  if (m) {
    let dayWord = '', period = '', hh = 0, mm = 0, what = '';
    if (/^(明天|今天|今晚)?$/.test(m[1] || '')) {          // 第一种写法
      dayWord = m[1] || '';
      hh = Number(m[2]); mm = Number(m[3] || 0); what = String(m[4] || '').trim();
    } else {                                                // 第二种写法（时间在前）
      period = m[1] || ''; dayWord = /明/.test(period) ? '明天' : (/今/.test(period) ? '今天' : '');
      hh = Number(m[2]); mm = Number(m[3] || 0); what = String(m[4] || '').trim();
      if (/下午|傍晚|晚上/.test(period) && hh < 12) hh += 12;
      if (/中午/.test(period) && hh < 11) hh += 12;
    }
    what = what.replace(/^[，,：:。\s]+/, '') || '该做事啦';
    const at = new Date();
    at.setSeconds(0, 0);
    at.setHours(Math.min(23, Math.max(0, hh)), Math.min(59, Math.max(0, mm)));
    if (dayWord === '明天' || at.getTime() <= Date.now()) at.setDate(at.getDate() + 1);
    const items = loadReminders();
    items.push({ id: uid('rm'), userId: user.id, text: what, at: at.getTime(), done: false, createdAt: now() });
    saveReminders(items);
    const isToday = at.toDateString() === new Date().toDateString();
    return '好，' + (isToday ? '今天' : '明天') + ' ' + ('0' + at.getHours()).slice(-2) + ':' + ('0' + at.getMinutes()).slice(-2) +
      ' 提醒你「' + what + '」。';
  }
  if (/^(我的)?提醒(列表|事项)?$/.test(t)) {
    const items = loadReminders().filter((r) => r.userId === user.id && !r.done && r.at > Date.now());
    if (!items.length) return '现在没有待办提醒。跟我说「提醒我 8:30 开会」就行。';
    return '你有 ' + items.length + ' 个提醒：\n' + items.map((r) => '· ' + new Date(r.at).toLocaleString('zh-CN', { hour12: false }) + ' ' + r.text).join('\n');
  }
  m = t.match(/^记账\s*([^\s\d]{1,14})\s*(\d+(?:\.\d{1,2})?)/);
  if (m) {
    const p = path.join(DATA_DIR, 'ledger.json');
    const led = readJson(p, { items: [] });
    if (!Array.isArray(led.items)) led.items = [];
    led.items.push({ id: uid('gd'), userId: user.id, what: m[1], amount: Number(m[2]), at: now() });
    writeJson(p, led);
    const month = led.items.filter((x) => x.userId === user.id && String(x.at || '').slice(0, 7) === now().slice(0, 7));
    const sum = month.reduce((s, x) => s + Number(x.amount || 0), 0);
    return '记好了：' + m[1] + ' ' + m[2] + ' 元。这个月一共 ' + sum.toFixed(2) + ' 元。';
  }
  if (/^(账本|这个月花了多少|花了多少钱)/.test(t)) {
    const led = readJson(path.join(DATA_DIR, 'ledger.json'), { items: [] });
    const items = Array.isArray(led.items) ? led.items : [];
    const month = items.filter((x) => x.userId === user.id && String(x.at || '').slice(0, 7) === now().slice(0, 7));
    if (!month.length) return '这个月还没记过账。跟我说「记账 午饭 25」就行。';
    const sum = month.reduce((s, x) => s + Number(x.amount || 0), 0);
    return '这个月记了 ' + month.length + ' 笔，共 ' + sum.toFixed(2) + ' 元。\n' +
      month.slice(-10).map((x) => '· ' + x.what + ' ' + x.amount + ' 元').join('\n');
  }
  /* ---------- 点餐 / 购物 ---------- */
  /* 淘宝那种卡片：App 收到就**直接跳转**（装了淘宝跳淘宝 App，没装用 App 内网页打开） */
  const sendShopCard = (title, sub, url, scheme, image, extra) => {
    try {
      const payload = Object.assign({
        title: title, sub: sub, url: url, scheme: scheme || '', image: image || ''
      }, extra || {});
      deliverMessage(bot, chat.id, 'link', JSON.stringify(payload), null);
    } catch (e) { }
  };
  /* 带图的链接卡片（微信里分享链接就是"缩略图 + 标题 + 说明"）：
     用户说「给我个带图链接」时发一张样例出来，方便看效果。
     ⚠ 必须放在 sendShopCard 定义之后 —— 放前面会踩 const 的 TDZ，整条指令直接报错。 */
  m = t.match(/(带图的?|图文)?(超链接|链接|连接)/) && t.match(/带图|图文/);
  if (m) {
    /* 按用户说的话题挑卡片 —— 以前不管说啥都回一张咖啡卡，用户反馈「乱推」。
       说到什么就给什么：酒店 / 机票 / 旅游 / 外卖 / 购物，什么都不沾就给一张搜索卡。 */
    const shop0 = loadShop();
    let kw = t.replace(/给我|发我|来个|来一张|发个|要|一张|一个|个|的|带图|图文|超链接|链接|连接|图片|图/g, '').trim();
    /* 抠出来的就是分类词本身（"酒店的带图超链接" → "酒店"）就别往文案里塞了 */
    if (/^(酒店|住宿|机票|航班|飞机|旅游|旅行|景点|门票|攻略|外卖|点餐|购物|淘宝|商品|卡片|超链接|链接)$/.test(kw)) kw = '';
    const foodImg = ((shop0.food || [])[0] || {}).img || '';
    const goodsImg = ((shop0.goods || [])[0] || {}).img || '';
    const cards = [
      { re: /酒店|住宿|订房|民宿|宾馆/, title: '亚龙湾万豪度假酒店',
        sub: '三亚 · 亚龙湾 · 含双早', url: 'https://m.ctrip.com/webapp/hotel/', scheme: 'ctrip://',
        img: '/uploads/card-hotel.png',
        extra: { meta: '三亚市豪华酒店人气榜第3名', reviews: '4.8分 · 6231条评价',
          prices: [{ price: '1088', off: '8.0折', tag: '【含双早】豪华海景房' },
                   { price: '888', off: '7.5折', tag: '【连住2晚】园景大床房' }] } },
      { re: /机票|航班|飞机|飞行/, title: '深圳 → 三亚', sub: '直飞 · 含税',
        url: 'https://m.ctrip.com/webapp/flight/', scheme: 'ctrip://', img: '/uploads/card-flight.png',
        extra: { meta: '经济舱 · 3 折起', reviews: '已含机建燃油',
          prices: [{ price: '680', off: '5.2折', tag: '【早鸟】07:20 起飞' },
                   { price: '920', off: '6.8折', tag: '【午间】12:45 起飞' }] } },
      { re: /旅游|旅行|景点|门票|攻略|度假|玩|三亚|三亚市/, title: '蜈支洲岛',
        sub: '三亚 · 5A 景区', url: 'https://m.ctrip.com/webapp/vacations/', scheme: 'ctrip://',
        img: '/uploads/card-travel.png',
        extra: { meta: '三亚市景点人气榜第1名 · 5A · 情侣', reviews: '11万条评价',
          prices: [{ price: '787', off: '8.5折', tag: '【国庆可用】蜈支洲岛当日购' },
                   { price: '287', off: '8.4折', tag: '【当日购】限定套餐' }] } },
      { re: /外卖|点餐|吃|餐|咖啡|奶茶|饭/, title: '美团外卖 · 点外卖', sub: '附近商家 · 30 分钟送到',
        url: 'https://h5.waimai.meituan.com/', scheme: 'imeituan://www.meituan.com/waimai', img: foodImg },
      { re: /买|购物|淘宝|商品|商城|东西/, title: '淘宝 · 搜同款', sub: '想买什么直接搜',
        url: 'https://main.m.taobao.com/', scheme: 'taobao://', img: goodsImg }
    ];
    const pick = cards.find((c) => c.re.test(t));
    if (pick) {
      sendShopCard(pick.title, pick.sub, pick.url, pick.scheme, pick.img, pick.extra);
    } else {
      sendShopCard('搜一下 · 百度', kw ? ('搜「' + kw + '」') : '想搜什么直接搜',
        kw ? ('https://m.baidu.com/s?wd=' + encodeURIComponent(kw)) : 'https://m.baidu.com/',
        '', '/uploads/card-web.png');
    }
    return '给你一张带图的链接卡片 👆\n左边缩略图、中间标题和说明、右边「打开」，'
      + '点了直接跳对应 App（没装就用 App 内的网页打开）。\n'
      + (pick ? '' : '想要别的类型也直接说，比如「酒店的带图超链接」「机票的带图链接」。');
  }
  m = t.match(/^(?:帮我)?(点餐|点外卖|点个外卖|外卖|我想吃点|我想吃|饿了|点单)$/) || t.match(/^帮我点(?:个|份)?(.{1,10})$/);
  if (m) {
    const shop = loadShop();
    const want = (m[1] || '').trim();
    let items = shop.food, kind = 'food';
    if (want && !/^(餐|外卖|单|个外卖)$/.test(want)) {
      const hit = shop.food.filter((x) => x.name.indexOf(want) >= 0);
      if (hit.length) items = hit;
    }
    lastShopMenu.set(user.id, { kind, items });
    const food = (want && !/^(餐|外卖|单|个外卖)$/.test(want)) ? want : items[0].name;
    const kw = encodeURIComponent(food);
    const foodImg = ((items.find((x) => x.name.indexOf(food) >= 0) || items[0] || {}).img) || '';
    sendShopCard('美团外卖 · 点外卖', '附近商家 · 30 分钟送到（搜「' + food + '」）',
      'https://h5.waimai.meituan.com/', 'imeituan://www.meituan.com/waimai', foodImg);
    return '点外卖走美团外卖，我已经给你跳过去了 👆\n想吃「' + food + '」在里边搜一下就行；' +
      '\n想用零钱在我这儿下单也行，说「点第 1 个」。余额 ' + money(user.balance);
  }
  m = t.match(/^(?:帮我)?(购物|买东西|买点东西|商城|逛商城|日用品)(?:\s+(.{1,12}))?$/) ||
      t.match(/^(?:帮我)?(?:在淘宝)?买\s*(.{1,12})$/) ||
      t.match(/^我想(?:买|要)\s*(.{1,12})$/);
  if (m && !/^第?\s*\d/.test(String(m[2] || m[1] || '').trim())) {
    const shop = loadShop();
    const want = String(m[2] || m[1] || '').trim();
    lastShopMenu.set(user.id, { kind: 'goods', items: shop.goods });
    const goods = (want && !/^(东西|点东西|商城|日用品)$/.test(want)) ? want : shop.goods[0].name;
    const kw2 = encodeURIComponent(goods);
    sendShopCard('淘宝 · 买「' + goods + '」', '同款比价 · 直接下单',
      'https://s.m.taobao.com/h5?q=' + kw2, 'taobao://s.taobao.com/search?q=' + kw2);
    return '买东西走淘宝，我已经给你跳过去了 👆\n在里边搜「' + goods + '」就能买；' +
      '\n想用零钱在我这儿下单也行，说「买第 1 个」。余额 ' + money(user.balance);
  }
  /* 点外卖的入口 / 逛淘宝：都给出去 */
  if (/^(美团|美团外卖|附近有什么吃的|点外卖的入口|饿了么)$/.test(t)) {
    sendShopCard('美团外卖', '附近商家 · 30 分钟送到', 'https://h5.waimai.meituan.com/', 'imeituan://www.meituan.com/waimai');
    return '这就给你打开美团外卖 👆 想吃什么直接告诉我，我帮你搜。';
  }
  if (/^(淘宝闪购|闪购)$/.test(t)) {
    sendShopCard('美团外卖 · 点外卖', '点外卖用美团，30 分钟送到', 'https://h5.waimai.meituan.com/', 'imeituan://www.meituan.com/waimai');
    return '点外卖用美团外卖最顺，我给你跳过去了 👆';
  }
  if (/^(淘宝|去淘宝|逛淘宝|淘宝首页)$/.test(t)) {
    const gs = loadShop().goods;
    sendShopCard('淘宝', '想买什么直接搜', 'https://main.m.taobao.com/', 'taobao://',
      (gs && gs[0] && gs[0].img) || '/uploads/shop_g10.png');
    return '这就给你打开淘宝 👆 要买什么直接说「买 耳机」，我帮你搜。';
  }
  m = t.match(/^(?:帮我)?(?:点|要|买|来|下单)\s*第?\s*(\d{1,2})\s*(?:个|份|号|杯|碗)?$/);
  if (m) {
    const menu = lastMenu(user.id);
    if (!menu) return '先跟我说「点餐」或者「购物」，我把清单给你。';
    const it = menu.items[Number(m[1]) - 1];
    if (!it) return '清单里只有 ' + menu.items.length + ' 项，你再说一次序号？';
    const bal = Number(user.balance) || 0;
    if (bal < it.price) return '余额不够啦（' + money(bal) + ' / 需要 ' + money(it.price) + '）。我 → 服务 → 充值余额 充一点就行。';
    user.balance = Math.round((bal - it.price) * 100) / 100;
    saveUsers();
    sendTo(user.id, { type: 'balance', balance: user.balance });
    const order = { id: uid('od'), userId: user.id, kind: menu.kind, name: it.name, price: it.price, at: now(), status: '已下单' };
    const orders = loadOrders();
    orders.unshift(order);
    saveOrders(orders.slice(0, 200));
    /* 顺手设个提醒：外卖 30 分钟、商品明天上午 */
    const at = new Date(Date.now() + (menu.kind === 'food' ? 30 * 60 * 1000 : 12 * 3600 * 1000));
    const rms = loadReminders();
    rms.push({ id: uid('rm'), userId: user.id, text: (menu.kind === 'food' ? '外卖应该到了：' : '记得收快递：') + it.name, at: at.getTime(), done: false, createdAt: now() });
    saveReminders(rms);
    const plat = 'https://s.m.taobao.com/h5?q=';
    return '下单成功 ✅\n· ' + it.name + '　' + money(it.price) + '\n· 已用零钱支付，余额 ' + money(user.balance) +
      '\n' + (menu.kind === 'food' ? '大概 30 分钟送到，我到点提醒你。' : '明天上午送到，我到点提醒你。') +
      '\n' + (menu.kind === 'food' ? '想再点别的，淘宝闪购：https://shangou.m.taobao.com/' : '想再买别的，淘宝：https://main.m.taobao.com/') +
      '\n同款比价：' + plat + encodeURIComponent(it.name);
  }
  if (/^(我的)?(订单|单子)$/.test(t)) {
    const mine = loadOrders().filter((x) => x.userId === user.id).slice(0, 5);
    if (!mine.length) return '你还没在我这儿下过单。说「点餐」或者「购物」试试。';
    return '你最近的订单：\n' + mine.map((x) => '· ' + x.name + '　' + money(x.price) + '　' + x.status).join('\n');
  }
  if (/^(AI)?余额(还剩多少)?$|^还剩多少(AI)?余额$|^api余额$/.test(t.replace(/\s/g, '')) && /AI|api/i.test(t)) {
    try {
      const cfgB = readAiCfg();
      const r = await fetch(String(cfgB.baseUrl || AI_DEFAULT.baseUrl).replace(/\/+$/, '') + '/user/balance', {
        headers: { Authorization: 'Bearer ' + cfgB.apiKey }, signal: AbortSignal.timeout(10000)
      });
      const d = await r.json().catch(() => ({}));
      const info = (d.balance_infos || [])[0] || {};
      return 'AI 账户余额：' + (info.currency === 'CNY' ? '¥' : '') + (info.total_balance || '0') + '（可用：' + (d.is_available ? '是' : '否，去 platform.deepseek.com 充一点') + '）';
    } catch (e) { return '查余额失败：' + (e && e.message); }
  }
  if (/^(余额|零钱|我还有多少钱|查余额)$/.test(t)) {
    return '你的零钱余额是 ' + money(user.balance) + '。要充值得去「我 → 服务 → 充值余额」。';
  }
  /* 用户说「和X聊天 / 找X」这种：不替他开聊天，只给个提示 */
  m = t.match(/^(?:帮我|替我)?(?:和|跟|找|联系|打开)\s*([^\s，,：:]{1,14})\s*(?:聊天|聊两句|聊一下|说话|的聊天)$/);
  if (m) return '这个我帮不上——你直接在通讯录里点他就能聊。要我替你带句话就说「给' + m[1] + '发消息 内容」。';

  /* 代发消息：给张三发消息 你好（名字可以只写一部分） */
  m = t.match(/^(?:帮我|替我)?给\s*([^\s，,：:]{1,14})\s*(?:发消息|发个消息|发条消息|说|留言)\s*[：:，,]?\s*([\s\S]+)$/);
  if (m) {
    const hits = findContacts(user, m[1]);
    if (!hits.length) return '没找到「' + m[1] + '」这个人，名字再准一点？';
    if (hits.length > 2) {
      return '有几个同名的，你要发给哪一个？\n' + hits.slice(0, 5).map((u, i) => (i + 1) + '. ' + (u.nickname || u.username)).join('\n');
    }
    const target = hits[0];
    const chat = openChatWith(user, target);
    deliverMessage(user, chat.id, 'text', m[2].trim(), null);
    return '已经帮你发给「' + (target.nickname || target.username) + '」：' + m[2].trim();
  }
  /* ---------- 朋友圈：写草稿 / 直接发 / 带刚才发的图 ---------- */
  function recentImage() {
    if (!chat) return '';
    const msgs = loadMessages(chat.id).filter((x) => !x.recalled);
    for (let i = msgs.length - 1; i >= 0 && i >= msgs.length - 6; i--) {
      if (msgs[i].kind === 'image') return String(msgs[i].content || '');
    }
    return '';
  }
  async function draftMoment(topic) {
    const cfg = readAiCfg();
    const ask = '帮用户写一条微信朋友圈文案' + (topic ? ('，主题是：' + topic) : '（就写今天的生活小感想）') +
      '。要求：口语化、真实、不超过 40 个字、可以带 1-2 个 emoji、不要引号也不要解释，只给文案本身。';
    let text = '';
    try { text = await llmChat([{ role: 'system', content: (cfg.housekeeperPrompt || AI_DEFAULT.housekeeperPrompt) }, { role: 'user', content: ask }], cfg); } catch (e) { }
    text = String(text || '').replace(/^["“”']|["“”']$/g, '').trim();
    return text || (topic || '今天也要好好生活呀 ☀️');
  }
  function postMoment(content, images) {
    const moment = { id: uid('mo'), authorId: user.id, content: String(content || '').slice(0, 1000), images: images || [], createdAt: now(), likes: [], comments: [] };
    db.moments.unshift(moment);
    saveMoments();
    broadcastMoment(user.id, { type: 'moment', action: 'new', authorId: user.id, moment: visibleMoment(moment, user.id) });
    return moment;
  }
  /* 写朋友圈（只要草稿，不发） */
  m = t.match(/^(?:帮我)?写(?:条|个)?(?:朋友圈|动态)(?:文案)?\s*[：:，,]?\s*([\s\S]*)$/);
  if (m) {
    const draft = await draftMoment(m[1].trim());
    lastDraft.set(user.id, draft);
    return '草稿给你：\n' + draft + '\n\n满意就说「发吧」，不满意就说「换一条」，也可以自己改。';
  }
  /* 发朋友圈：带内容就发内容，只写「帮我发朋友圈」就让它自己写一条 */
  m = t.match(/^(?:帮我|替我|你)?发(?:条|个)?(?:朋友圈|动态)\s*[：:，,]?\s*([\s\S]*)$/);
  if (m) {
    const body = m[1].trim();
    const img = recentImage();
    const images = img ? [img] : [];
    let content = body;
    if (!content || /^(吧|呗|一条|一条吧|随便|你写|你来写|自己写)?$/.test(content) || /^主题[：:]/.test(content) || content.length <= 2) {
      content = await draftMoment(content.replace(/^主题[：:]/, '').trim());
    }
    postMoment(content, images);
    return '朋友圈已经发出去啦' + (images.length ? '（带上了你刚发的那张图）' : '') + '：「' + content + '」\n不满意就说「重发一条 主题：…」，我把刚才那条删了重发。';
  }
  if (/^(发吧|直接发|发出去|发这个|就发这个|可以发|发$|发了|发一条|发吧发吧)/.test(t)) {
    const draft = lastDraft.get(user.id);
    if (!draft) return '你想发什么内容？先说「写条朋友圈 主题」让我写，或者直接说「发朋友圈 内容」。';
    postMoment(draft, []);
    lastDraft.delete(user.id);
    return '好嘞，已经帮你发到朋友圈了：「' + draft + '」';
  }
  if (/^(换一条|换一个|不满意|重写|再来一条)/.test(t)) {
    const draft = await draftMoment('');
    lastDraft.set(user.id, draft);
    return '换一条：\n' + draft + '\n满意就说「发吧」。';
  }
  m = t.match(/^(?:重发|重新发)(?:一条)?\s*[：:，,]?\s*([\s\S]*)$/);
  if (m) {
    const mine = db.moments.filter((x) => x.authorId === user.id).sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))[0];
    if (mine) { db.moments = db.moments.filter((x) => x.id !== mine.id); saveMoments(); }
    const content = await draftMoment(m[1].replace(/^主题[：:]/, '').trim());
    postMoment(content, (mine && mine.images) || []);
    return '好，重发了一条：「' + content + '」';
  }
  /* 改签名 */
  m = t.match(/^(?:帮我)?(?:改|写)(?:个)?签名\s*[：:，,]?\s*([\s\S]*)$/);
  if (m) {
    const cfg2 = readAiCfg();
    let bio = m[1].trim();
    if (!bio) {
      try { bio = await llmChat([{ role: 'system', content: '你帮用户想一句微信个性签名：中文、不超过 20 字、有点个性、不要引号，只给签名本身。' }], cfg2); } catch (e) { }
    }
    bio = String(bio || '').replace(/^["“”']|["“”']$/g, '').trim().slice(0, 40);
    if (!bio) return '你想写什么样的签名？比如「改签名 岁月静好」。';
    user.bio = bio;
    saveUsers();
    return '签名已改成：' + bio;
  }
  if (/^(开启|打开).*(自动回复)/.test(t)) {
    saveAiCfg({ autoReply: true });
    return '好的，自动回复已开启：你不在线的时候，收到消息我先替你回一句。想关掉就说「关闭自动回复」。';
  }
  if (/^(关闭|取消).*(自动回复)/.test(t)) {
    saveAiCfg({ autoReply: false });
    return '自动回复已经关掉了。';
  }

  /* ============================================================
     替用户在 App 里干活（微信「小微」那种）。下面这些命令都不走大模型，
     说一句就直接把事办了 —— 建群 / 加好友 / 改昵称 / 会话管理 /
     查聊天记录 / 朋友圈点赞评论 / 转账 / 账单 / 谁在线 / 清空记录
     ============================================================ */

  /* ① 建群：建个群 张三 李四 */
  m = t.match(/^(?:帮我|替我)?(?:建|开|拉|创)(?:个|一个)?(?:群|群聊|讨论组)\s*[：:，,]?\s*([\s\S]*)$/);
  if (m) {
    const names = m[1].trim().split(/[\s、,，+和跟与]+/).map((x) => x.trim()).filter(Boolean);
    if (!names.length) return '要拉谁进群？这样说：「建个群 张三 李四」。';
    const picked = [];
    const missing = [];
    names.forEach((n) => {
      const hits = findContacts(user, n).filter((u) => !u.bot);
      if (hits.length) { if (!picked.some((x) => x.id === hits[0].id)) picked.push(hits[0]); }
      else missing.push(n);
    });
    if (!picked.length) return '没找到这些人：' + names.join('、') + '。名字写准一点再试一次。';
    const gname = ((user.nickname || user.username || '我') + '、' +
      picked.map((u) => u.nickname || u.username).join('、')).slice(0, 30);
    const gchat = {
      id: uid('c'), type: 'group', name: gname, avatar: '',
      memberIds: [user.id].concat(picked.map((u) => u.id)),
      ownerId: user.id, seq: 0, createdAt: now()
    };
    db.chats.push(gchat);
    try { buildGroupAvatar(gchat); } catch (e) { }
    saveChats();
    gchat.memberIds.forEach((id) => {
      if (id !== user.id) sendTo(id, { type: 'chat', action: 'created', chat: chatSummary(gchat, id) });
    });
    return '群建好了：「' + gchat.name + '」（' + gchat.memberIds.length + ' 人）' +
      (missing.length ? '\n没找到：' + missing.join('、') : '') + '\n在「微信」第一页就能看到这个群。';
  }

  /* ② 加好友：加好友 wzy245441549 */
  m = t.match(/^(?:帮我|替我)?(?:加|添加|新增|加上)\s*(?:好友|朋友|联系人|微信号)?\s*[：:，,]?\s*([A-Za-z0-9_\-.\u4e00-\u9fa5]{2,24})$/);
  if (m) {
    const kw = m[1].trim();
    const target = findUserByName(kw) || findContacts(user, kw).filter((u) => !u.bot)[0];
    if (!target) return '没找到「' + kw + '」这个人。把微信号发我（比如「加好友 wzy245441549」）。';
    if (target.id === user.id) return '这是你自己呀～';
    const who = target.nickname || target.username;
    if (friendIds(user.id).includes(target.id)) return '你和「' + who + '」已经是好友了，直接聊就行。';
    const f = friendshipBetween(user.id, target.id);
    if (f) {
      if (f.status === 'accepted') return '你们已经是好友了。';
      if (f.fromId === user.id) return '好友申请已经发过了，等「' + who + '」在「新的朋友」里通过。';
      f.status = 'accepted';
      saveFriendships();
      openChatForFriendship(f.fromId, f.toId);
      sendTo(target.id, { type: 'friend', action: 'accepted', user: publicUser(user) });
      return '「' + who + '」之前加过你，现在你们互相是好友了，可以聊天了。';
    }
    db.friendships.push({ id: uid('f'), fromId: user.id, toId: target.id, status: 'pending', createdAt: now(),
      note: str(body.message, 60) });
    saveFriendships();
    sendTo(target.id, { type: 'friend', action: 'request', user: publicUser(user) });
    return '好友申请已经发给「' + who + '」了，等对方通过。';
  }

  /* ③ 改昵称：改昵称 小明 */
  m = t.match(/^(?:帮我)?(?:改|换)(?:个)?(?:昵称|名字)\s*[：:，,]?\s*(\S{1,20})$/);
  if (m && !/签名/.test(t)) {
    const nn = m[1].trim().slice(0, 20);
    user.nickname = nn;
    saveUsers();
    return '昵称已经改成「' + nn + '」了。';
  }

  /* ④ 会话管理：置顶 / 免打扰 / 删掉 / 清空记录 */
  const chatActs = {
    '置顶': 'pin', '取消置顶': 'unpin',
    '免打扰': 'mute', '取消免打扰': 'unmute',
    '静音': 'mute', '取消静音': 'unmute',
    '删掉': 'del', '删除': 'del', '隐藏': 'del',
    '清空': 'clear', '清空记录': 'clear', '清空聊天记录': 'clear'
  };
  m = t.match(/^(?:帮我)?(?:把)?\s*(?:和|跟)?\s*([^\s，,：:的]{1,14})\s*(?:的)?\s*(?:聊天记录|聊天|会话|对话)?\s*(置顶|取消置顶|免打扰|取消免打扰|静音|取消静音|删掉|删除|隐藏|清空|清空记录|清空聊天记录)$/)
    || t.match(/^(?:帮我)?(置顶|取消置顶|免打扰|取消免打扰|静音|取消静音|删掉|删除|隐藏|清空|清空记录|清空聊天记录)\s*(?:和|跟)?\s*([^\s，,：:的]{1,14})\s*(?:的)?\s*(?:聊天记录|聊天|会话|对话)?$/);
  if (m && Object.prototype.hasOwnProperty.call(chatActs, m[1] === undefined ? '' : m[1])) {
    /* 两种语序：名字在前 or 动作在前 */
    const firstIsAct = Object.prototype.hasOwnProperty.call(chatActs, m[1]);
    const name = String((firstIsAct ? m[2] : m[1]) || '').trim();
    const act = chatActs[firstIsAct ? m[1] : m[2]];
    const hits = findContacts(user, name).filter((u) => !u.bot);
    if (!hits.length) return '没找到「' + name + '」这个人。';
    const target = hits[0];
    const who = target.nickname || target.username;
    const chat = directChatBetween(user.id, target.id);
    if (!chat) return '你和「' + who + '」还没有会话。';
    if (act === 'pin' || act === 'unpin') {
      const set = new Set(chat.pinnedFor || []);
      if (act === 'pin') set.add(user.id); else set.delete(user.id);
      chat.pinnedFor = Array.from(set);
      saveChats();
      return act === 'pin' ? '已经把「' + who + '」置顶了。' : '已经取消置顶了。';
    }
    if (act === 'mute' || act === 'unmute') {
      const set = new Set(chat.mutedFor || []);
      if (act === 'mute') set.add(user.id); else set.delete(user.id);
      chat.mutedFor = Array.from(set);
      saveChats();
      sendTo(user.id, { type: 'chat', action: 'updated', chat: chatSummary(chat, user.id) });
      return act === 'mute' ? '已经给「' + who + '」设成消息免打扰了。' : '已经取消免打扰了。';
    }
    if (act === 'del') {
      chat.hiddenFor = Array.from(new Set((chat.hiddenFor || []).concat([user.id])));
      saveChats();
      sendTo(user.id, { type: 'chat', action: 'removed', chatId: chat.id });
      return '已经把和「' + who + '」的会话从列表里去掉（对方不受影响，再来消息会重新出现）。';
    }
    const msgs = loadMessages(chat.id);
    const lastSeq = msgs.length ? msgs[msgs.length - 1].seq : 0;
    if (!db.cleared[user.id]) db.cleared[user.id] = {};
    db.cleared[user.id][chat.id] = lastSeq;
    if (!db.reads[user.id]) db.reads[user.id] = {};
    db.reads[user.id][chat.id] = lastSeq;
    saveReads();
    return '和「' + who + '」的聊天记录在你这台设备上清空了（对方那边还在）。';
  }

  /* ⑤ 查聊天记录：我和张三聊了什么 / 找张三说过 合同 */
  m = t.match(/^(?:找|搜|查)\s*([^\s，,：:的]{1,14})\s*(?:说过|说的|发过|发的)\s*[：:，,]?\s*([\s\S]{1,20})$/);
  if (m) {
    const hits = findContacts(user, m[1]).filter((u) => !u.bot);
    if (!hits.length) return '没找到「' + m[1] + '」这个人。';
    const target = hits[0];
    const who = target.nickname || target.username;
    const chat = directChatBetween(user.id, target.id);
    if (!chat) return '你和「' + who + '」还没有聊天记录。';
    const kw = m[2].trim();
    const found = loadMessages(chat.id).filter((x) => !x.recalled && String(x.content || '').indexOf(kw) >= 0).slice(-5);
    if (!found.length) return '你和「' + who + '」的聊天里没找到「' + kw + '」。';
    return '在「' + who + '」那儿找到 ' + found.length + ' 条：\n' +
      found.map((x) => '· ' + (x.senderId === user.id ? '我：' : (who + '：')) + String(x.content || '').slice(0, 40)).join('\n');
  }
  m = t.match(/^(?:我和|查|看看|找)\s*([^\s，,：:的]{1,14})\s*(?:的)?(?:聊天记录|聊天|聊了什么|聊了啥|记录)$/);
  if (m) {
    const hits = findContacts(user, m[1]).filter((u) => !u.bot);
    if (!hits.length) return '没找到「' + m[1] + '」这个人。';
    const target = hits[0];
    const who = target.nickname || target.username;
    const chat = directChatBetween(user.id, target.id);
    if (!chat) return '你和「' + who + '」还没有聊过。';
    const msgs = loadMessages(chat.id).filter((x) => !x.recalled).slice(-8);
    if (!msgs.length) return '你和「' + who + '」还没有聊天记录。';
    return '你和「' + who + '」最近 ' + msgs.length + ' 条：\n' +
      msgs.map((x) => '· ' + (x.senderId === user.id ? '我：' : (who + '：')) + (x.kind === 'text' ? String(x.content || '').slice(0, 40) : '[' + x.kind + ']')).join('\n');
  }

  /* ⑥ 朋友圈：点赞 / 评论 */
  m = t.match(/^(?:帮我)?(?:给)?\s*([^\s，,：:的]{1,14})\s*(?:的)?(?:最新)?(?:朋友圈|动态)\s*(?:点个赞|点赞)$/);
  if (m) {
    const hits = findContacts(user, m[1]).filter((u) => !u.bot);
    const target = hits[0];
    if (!target) return '没找到「' + m[1] + '」这个人。';
    const who = target.nickname || target.username;
    const mm = db.moments.filter((x) => x.authorId === target.id)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))[0];
    if (!mm) return '「' + who + '」最近没发朋友圈。';
    if (!momentAudience(mm.authorId).includes(user.id)) return '看不到「' + who + '」的朋友圈（对方设了权限）。';
    if (!mm.likes) mm.likes = [];
    if (!mm.likes.some((l) => l.userId === user.id)) mm.likes.push({ userId: user.id, at: now() });
    saveMoments();
    broadcastMoment(mm.authorId, { type: 'moment', action: 'like', momentId: mm.id, authorId: mm.authorId, userId: user.id, liked: true });
    return '已经给「' + who + '」的朋友圈点了个赞 👍';
  }
  m = t.match(/^(?:帮我)?(?:给)?\s*([^\s，,：:的]{1,14})\s*(?:的)?(?:最新)?(?:朋友圈|动态)\s*评论\s*[：:，,]?\s*([\s\S]{1,120})$/);
  if (m) {
    const hits = findContacts(user, m[1]).filter((u) => !u.bot);
    const target = hits[0];
    if (!target) return '没找到「' + m[1] + '」这个人。';
    const who = target.nickname || target.username;
    const mm = db.moments.filter((x) => x.authorId === target.id)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))[0];
    if (!mm) return '「' + who + '」最近没发朋友圈。';
    if (!momentAudience(mm.authorId).includes(user.id)) return '看不到「' + who + '」的朋友圈（对方设了权限）。';
    if (!mm.comments) mm.comments = [];
    mm.comments.push({ id: uid('cm'), userId: user.id, content: m[2].trim(), replyTo: null, at: now() });
    saveMoments();
    const views = visibleMoment(mm, user.id);
    momentAudience(mm.authorId).forEach((id) => {
      sendTo(id, {
        type: 'moment', action: 'comment', momentId: mm.id, authorId: mm.authorId,
        comment: views.comments[views.comments.length - 1], commentCount: views.comments.length
      });
    });
    return '已经在「' + who + '」的朋友圈下面评论了：' + m[2].trim();
  }

  /* ⑦ 转账：先报一句「给张三转 50」，我说确认才真的转 */
  if (/^(算了|取消|不转了|不用了)$/.test(t) && aiTodo.get(user.id)) {
    aiTodo.delete(user.id);
    return '好，那件事取消了。';
  }
  m = t.match(/^(?:帮我|替我)?(?:给)?\s*([^\s，,：:]{1,14}?)\s*(?:转账|转钱|转|打钱)\s*([0-9]+(?:\.[0-9]{1,2})?)\s*(?:元|块钱|块|元整)?$/)
    || t.match(/^(?:帮我|替我)?(?:转账|转钱|转)\s*([0-9]+(?:\.[0-9]{1,2})?)\s*(?:元|块钱|块)?\s*(?:给)?\s*([^\s，,：:]{1,14})$/);
  if (m) {
    let name = '', amt = 0;
    if (/^[0-9]/.test(m[1])) { amt = Number(m[1]); name = String(m[2] || '').trim(); }
    else { name = String(m[1] || '').trim(); amt = Number(m[2]); }
    if (!(amt > 0)) return '转账金额要大于 0，比如「给张三转 50」。';
    if (amt > 200000) return '单笔最多 20 万。';
    const limit = user.transferLimit === undefined ? 20000 : (Number(user.transferLimit) || 0);
    if (limit > 0 && amt > limit) return '超过你的单笔限额 ' + money(limit) + ' 了。';
    const hits = findContacts(user, name).filter((u) => !u.bot);
    if (!hits.length) return '没找到「' + name + '」这个人。';
    const who = hits[0].nickname || hits[0].username;
    aiTodo.set(user.id, { kind: 'transfer', toId: hits[0].id, name: who, amount: amt });
    return '确认给「' + who + '」转 ' + money(amt) + ' 吗？\n确认就回「确认转账' +
      (hasPayPassword(user) ? ' 支付密码' : '') + '」，不想转就说「算了」。';
  }
  m = t.match(/^(?:确认转账|确认付款|确认付款码|转吧|确认)\s*([0-9]{4,8})?$/);
  if (m) {
    const todo = aiTodo.get(user.id);
    if (!todo || todo.kind !== 'transfer') {
      return '现在没有等你确认的转账哦。想转就说「给张三转 50」，我先跟你确认一遍再转。';
    }
    const pwd = String(m[1] || '').trim();
    if (hasPayPassword(user) && !pwd) return '要支付密码才能转，回我「确认转账 你的支付密码」。';
    if (hasPayPassword(user) && !verifyPayPassword(user, pwd)) return '支付密码不对，再试一次。';
    const target = findUser(todo.toId);
    if (!target) { aiTodo.delete(user.id); return '这个人找不到了，重新说一次吧。'; }
    const bal = Number(user.balance) || 0;
    if (bal < todo.amount) {
      aiTodo.delete(user.id);
      return '余额不够（' + money(bal) + ' / 要 ' + money(todo.amount) + '）。去「我 → 服务 → 充值余额」充一点。';
    }
    user.balance = Math.round((bal - todo.amount) * 100) / 100;
    saveUsers();
    const c = openChatWith(user, target);
    const tr = {
      id: uid('tr'), chatId: c.id, fromId: user.id, toId: target.id, amount: todo.amount,
      note: '', method: 'balance', status: 'pending', createdAt: now(),
      expiresAt: Date.now() + TRANSFER_TTL_MS, receivedAt: '', refundedAt: '', messageId: ''
    };
    db.transfers.unshift(tr);
    if (db.transfers.length > 800) db.transfers.length = 800;
    const sent = deliverMessage(user, c.id, 'transfer', transferSnapshot(tr), null);
    if (sent && sent.error) {
      db.transfers = db.transfers.filter((x) => x.id !== tr.id);
      user.balance = Math.round(bal * 100) / 100;
      saveUsers();
      aiTodo.delete(user.id);
      return '转账没发出去：' + sent.error;
    }
    tr.messageId = sent.message.id;
    syncTransferMessage(tr);
    saveTransfers();
    sendTo(user.id, { type: 'balance', balance: user.balance });
    aiTodo.delete(user.id);
    return '已经转 ' + money(todo.amount) + ' 给「' + (target.nickname || target.username) + '」了' +
      '，对方点「收钱」才进他余额。你现在余额 ' + money(user.balance) + '。';
  }

  /* ⑧ 账单 */
  if (/^(我的)?(账单|收支|消费记录|交易记录|转账记录)$/.test(t)) {
    const rows = (db.transfers || []).filter((x) => x.fromId === user.id || x.toId === user.id).slice(0, 6);
    if (!rows.length) return '你和别人还没有转账记录。';
    return '最近 ' + rows.length + ' 笔：\n' + rows.map((x) => {
      const out = x.fromId === user.id;
      const other = findUser(out ? x.toId : x.fromId) || {};
      const st = x.status === 'received' ? '已收款' : (x.status === 'refunded' ? '已退回' : '待收款');
      return '· ' + (out ? '转出 ' : '收到 ') + money(x.amount) + '　' + (other.nickname || '') + '　' + st;
    }).join('\n');
  }

  /* ⑨ 谁在线 */
  if (/^(谁在线|都有谁在线|在线的人|谁在)$/.test(t)) {
    const online = onlineUserIds();
    const list2 = friendIds(user.id).filter((id) => online.includes(id)).map(findUser)
      .filter((u) => u && !u.bot);
    if (!list2.length) return '现在好友里没有人在线。';
    return '在线的好友（' + list2.length + ' 个）：' + list2.slice(0, 10).map((u) => u.nickname || u.username).join('、');
  }

  return '';
}
async function botAnswer(bot, chat, user, text) {
  const cfg = readAiCfg();
  const query = String(text || '').slice(0, 800);
  const isHousekeeper = bot.username === 'housekeeper';
  if (bot.username === 'qqnews') return newsBotAnswer(bot, chat, user, query);
  if (isHousekeeper) {
    const cmd = await housekeeperCommand(user, query, chat, bot);
    if (cmd) return cmd;
  }
  const who = (user.nickname || user.username || '用户');
  const howToCall = user.gender === 'female' ? '女士' : (user.gender === 'male' ? '先生' : '您');
  const whoLine = '\n【记住】当前跟你说话的是「' + who + '」（账号资料里的性别是「' + (user.gender === 'female' ? '女' : (user.gender === 'male' ? '男' : '未填')) + '」），称呼对方用「' + howToCall + '」，别叫错、也别问对方性别。';
  const sys = isHousekeeper
    ? (cfg.housekeeperPrompt || AI_DEFAULT.housekeeperPrompt || cfg.systemPrompt) + whoLine
    : ((cfg.assistantPrompt || AI_DEFAULT.assistantPrompt || cfg.systemPrompt) + whoLine);
  const messages = [{ role: 'system', content: sys }];
  const histLimit = isHousekeeper ? 8 : (Number(cfg.history) || 12);
  if (needsSearch(query)) {
    const hits = await webSearch(query);
    if (hits.length) {
      messages.push({
        role: 'system',
        content: '下面是刚刚联网查到的资料，请据此回答（不要编造，拿不准就直说）：\n' + hits.map((h, i) => (i + 1) + '. ' + h).join('\n')
      });
    }
  }
  historyFor(chat.id, bot.id, histLimit).forEach((m) => messages.push(m));
  const useCfg = isHousekeeper ? Object.assign({}, cfg, { temperature: 0.7 }) : cfg;
  const reply = await llmChat(messages, useCfg);
  let out = reply || '我刚才走神了，您再说一遍？';
  if (user.gender === 'male' || user.gender === 'female') {          // 称呼兜底，保证不会叫错
    const want = user.gender === 'female' ? '女士' : '先生';
    const wrong = user.gender === 'female' ? '先生' : '女士';
    out = out.split(wrong).join(want);
  }
  return out;
}
function scheduleBotReply(bot, chat, fromUser, text) {
  const cfg = readAiCfg();
  if (!cfg.enabled) return;
  if (!cfg.apiKey) {
    try { deliverMessage(bot, chat.id, 'text', '（还没配置 AI 密钥：打开 ' + '/ai.html' + ' 填一下就能聊了）', null); } catch (e) { }
    return;
  }
  botAnswer(bot, chat, fromUser, text).then((reply) => {
    if (reply) deliverMessage(bot, chat.id, 'text', reply, null);
  }).catch((err) => {
    const msg = String((err && err.message) || '');
    console.error('[bot] ' + msg);
    let tip = '我这边网络卡了一下，再发一次试试～';
    if (/insufficient|balance|余额|402/i.test(msg)) {
      tip = '不好意思，AI 的余额用完了，我得先停一下。\n去 platform.deepseek.com 充一点就行（充 5 块能用很久），充完直接跟我说句话我就继续干活。';
    } else if (/abort|timeout|timed out/i.test(msg)) {
      tip = '这次等太久了（网络慢），你再说一遍，我重新算。';
    } else if (/401|api key|unauthor/i.test(msg)) {
      tip = 'AI 密钥好像不对了，去后台 ai.html 重新贴一下密钥。';
    }
    try { deliverMessage(bot, chat.id, 'text', tip, null); } catch (e) { }
  });
}


/* 自动回复：对方不在线时，用 AI 以「对方本人」的口吻回一句 */
/* 第一次上线：给主要账号各开一个和机器人的会话，并打声招呼 */
/* 新注册的用户也要有机器人：加好友 + 开个欢迎会话（否则他的会话列表是空的） */
function attachBotsFor(user) {
  if (!user || user.bot) return;
  const hello = {
    ai: '你好，我是 AI 助手 👋\n只负责这个 App 怎么用：哪找不到、怎么操作都可以问我。',
    housekeeper: '您好，我是 AI 助手，随时为您效劳 👋\n可以这样使唤我：\n· 提醒我 8:30 开会\n· 天气 上海\n· 记账 午饭 25\n· 给张三发消息 你好\n· 发朋友圈 今天天气真好',
    qqnews: '我是星联世界，想看什么新闻跟我说一声就行。'
  };
  let changed = false;
  /* service 账号（在线客服）不算这里的「机器人」：不给所有人建欢迎会话 */
  db.users.filter((u) => u.bot && !u.service).forEach((bot) => {
    if (bot.id === user.id) return;
    const f = friendshipBetween(user.id, bot.id);
    if (!f) {
      db.friendships.push({ id: uid('f'), fromId: bot.id, toId: user.id, status: 'accepted', createdAt: now() });
      changed = true;
    } else if (f.status !== 'accepted') {
      f.status = 'accepted';
      changed = true;
    }
    let chat = directChatBetween(user.id, bot.id);
    if (!chat) chat = createDirectChat(user.id, bot.id);
    const msgs = loadMessages(chat.id);
    if (!msgs.some((m) => m.senderId === bot.id)) {
      try {
        const r = deliverMessage(bot, chat.id, 'text', hello[bot.username] || '你好，我是机器人', null);
        if (r && r.error) console.log('[bots] 给 ' + user.username + ' 发 ' + bot.username + ' 的欢迎语失败：' + r.error);
      } catch (e) { console.log('[bots] 异常：' + e.message); }
    }
  });
  try { ensureSysChat(user); } catch (e) {}
  if (changed) saveFriendships();
}

/* 「星言团队」那个官方号：给每个用户都开一条会话（微信里「微信团队」一直躺在列表里）。
   第一次建这条会话时发一张欢迎卡片，让人知道这个号是干嘛的。 */
/** 把「星言团队」和所有人之间的好友关系删掉（只在开服时跑一遍） */
function dropSysFriendships() {
  try {
    const before = db.friendships.length;
    db.friendships = db.friendships.filter((f) => f.fromId !== SYS_ACCOUNT_ID && f.toId !== SYS_ACCOUNT_ID);
    const gone = before - db.friendships.length;
    if (gone > 0) { saveFriendships(); console.log("[官方号] 清掉星言团队的好友关系 " + gone + " 条"); }
    return gone;
  } catch (e) { return 0; }
}

function ensureSysChat(user) {
  try {
    if (!user || user.bot) return null;
    const sys = sysAccount();
    if (!sys || sys.id === user.id) return null;
    /* **不加好友**（用户要求「把团队的朋友啥的去掉」）：只留一条会话，
       通讯录 / 名片里都不出现它 —— 它是个系统通知号，不是好友。 */
    let chat = directChatBetween(user.id, sys.id);
    if (!chat) {
      chat = createDirectChat(user.id, sys.id);
      try {
        const cfg = readSysNoticeCfg();
        if (cfg.enabled && cfg.types.notice !== 0) {
          deliverMessage(sys, chat.id, 'sysnotice',
            JSON.stringify({ title: '欢迎使用星言', text: '这里是星言团队。账号安全、支付、公告这些事都由我来通知你：换了新设备登录、改了密码、改了手机号、收到转账，我都会在这儿给你留一条。', at: Date.now() }), '');
        }
      } catch (e) {}
    }
    return chat;
  } catch (e) { return null; }
}

function welcomeBots() {
  const main = db.users.find((u) => u.username === 'jdhhehe');
  if (!main) return;
  const hello = {
    ai: '你好，我是 AI 助手，只负责这个 App 的使用问题 👋\n哪找不到、怎么操作都可以问我，比如「怎么换头像」「朋友圈在哪发」。',
    housekeeper: '您好，我是 AI 助手，随时为您效劳 👋 整个微信里的事都能使唤我：\n· 给张三发消息 你好\n· 建个群 张三 李四　· 加好友 wzy245441549\n· 提醒我 8:30 开会　· 天气 上海　· 记账 午饭 25 / 账本\n· 发朋友圈 今天天气真好 / 写条朋友圈 加班 / 改签名 岁月静好\n· 给张三的朋友圈点赞 / 评论张三的朋友圈：好看\n· 置顶 张三 / 免打扰 张三 / 删掉 张三 / 清空和张三的聊天记录\n· 我和张三聊了什么 / 找张三说过 合同\n· 给张三转 50　· 我的账单　· 谁在线　· 余额'
  };
  db.users.filter((u) => u.bot && !u.service).forEach((bot) => {
    let chat = directChatBetween(main.id, bot.id);
    if (!chat) chat = createDirectChat(main.id, bot.id);
    const msgs = loadMessages(chat.id);
    if (msgs.some((m) => m.senderId === bot.id)) return;
      try {
        const r = deliverMessage(bot, chat.id, 'text', hello[bot.username] || '你好，我是机器人', null);
        if (r && r.error) console.log('[bots] 给 ' + user.username + ' 发 ' + bot.username + ' 欢迎语失败：' + r.error);
      } catch (e) { console.log('[bots] 给 ' + user.username + ' 发欢迎语异常：' + e.message); }
  });
}

function scheduleAutoReply(owner, chat, fromUser, text) {
  const cfg = readAiCfg();
  const sys = '你是「' + (owner.nickname || owner.username) + '」，正在微信里跟朋友聊天。现在你没空看手机，' +
    '先自动回一句客气、简短、自然的中文（20 字以内），不要暴露你是 AI，也不要承诺具体时间。';
  const messages = [{ role: 'system', content: sys }];
  historyFor(chat.id, owner.id, 6).slice(-6).forEach((m) => messages.push(m));
  llmChat(messages, Object.assign({}, cfg, { maxTokens: 120 })).then((reply) => {
    if (reply) deliverMessage(owner, chat.id, 'text', reply, null);
  }).catch((err) => { console.error('[autoreply] ' + (err && err.message)); });
}

function recallMessage(user, chatId, messageId) {
  const chat = db.chats.find((c) => c.id === chatId);
  if (!chat || !chat.memberIds.includes(user.id)) return { error: '会话不存在' };
  const messages = loadMessages(chat.id);
  const msg = messages.find((m) => m.id === messageId);
  if (!msg) return { error: '消息不存在' };
  if (msg.senderId !== user.id) return { error: '只能撤回自己的消息' };
  const windowMs = readIm().recallMinutes > 0 ? readIm().recallMinutes * 60 * 1000 : RECALL_WINDOW_MS;
  if (readIm().recallMinutes === 0) return { error: '管理员关闭了消息撤回' };
  if (Date.now() - new Date(msg.createdAt).getTime() > windowMs) {
    return { error: '超过 ' + readIm().recallMinutes + ' 分钟，不能撤回' };
  }
    msg.recalled = true;
    saveMessagesFile(chat.id, messages);
  sendToChat(chat, { type: 'recall', chatId: chat.id, messageId: msg.id });
  return { message: msg };
}

/* ------------------------------------------------------------------ HTTP */

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.gif': 'image/gif',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
  /* 视频/音频要给对类型：返回 octet-stream 时播放器只能靠猜格式，
     有的机型会直接黑屏或者卡一下才开始播 */
  '.mp4': 'video/mp4',
  '.m4v': 'video/mp4',
  '.mov': 'video/quicktime',
  '.webm': 'video/webm',
  '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.aac': 'audio/aac',
  '.ogg': 'audio/ogg',
  '.wav': 'audio/wav',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.eot': 'application/vnd.ms-fontobject',
  '.webm': 'audio/webm',
  '.ogg': 'audio/ogg',
  '.oga': 'audio/ogg',
  '.m4a': 'audio/mp4',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav'
};

/** 「媒体外挂」地址：后台 branding.mediaBase（空 = 还是走本机） */
let mediaBaseCache = { at: 0, url: '' };
function mediaBaseUrl() {
  if (Date.now() - mediaBaseCache.at < 30000) return mediaBaseCache.url;
  let url = '';
  try {
    const b = readJson(path.join(DATA_DIR, 'branding.json'), {});
    const v = String((b.branding && b.branding.mediaBase) || '').trim().replace(/\/+$/, '');
    if (/^https?:\/\//i.test(v)) url = v;
  } catch (e) { url = ''; }
  mediaBaseCache = { at: Date.now(), url };
  return url;
}

/* 出站统一套上「媒体外挂」：/uploads/ 和 /hls/ 都指到媒体机（后台 branding.mediaBase 配）。
   注意要连**实时推送**一起处理 —— 只改 HTTP 的话，刚收到的新图片还是从应用机拉。 */
function applyMediaBase(text) {
  const base = mediaBaseUrl();
  if (!base || !text) return text;
  if (text.indexOf('"/uploads/') >= 0) text = text.split('"/uploads/').join('"' + base + '/uploads/');
  if (text.indexOf('"/hls/') >= 0) text = text.split('"/hls/').join('"' + base + '/hls/');
  return text;
}

function sendJson(res, status, payload, headers) {
  /* 界面打包进 App 的版本是从 file:// / 自定义协议发请求的，跨域带不了 Cookie，
     所以只要这次响应里在发会话 Cookie，就顺手把同一个令牌放进响应体，
     客户端存下来，之后用 Authorization: Bearer 带上。网页版完全不受影响。 */
  try {
    const setCookie = headers && headers['Set-Cookie'];
    const raw = Array.isArray(setCookie) ? setCookie.join(';') : String(setCookie || '');
    const m = raw.match(new RegExp(COOKIE_NAME + '=([^;]+)'));
    if (m && payload && payload.ok !== false && payload.data && !payload.data.token && m[1]) {
      payload.data = Object.assign({}, payload.data, { token: m[1] });
    }
  } catch (err) { /* 忽略 */ }
  /* 出站把上传文件路径换成长签名链接：别人拿到链接也打不开 */
  let body = applyMediaBase(signUploadsInText(JSON.stringify(payload)));
  /* JSON 压缩：列表类接口（通讯录、朋友圈、会话）在 4G 上能少传一半以上，
     手机上"转圈"的时间明显缩短。gzip 是 Node 自带的，不装任何东西。 */
  const head = Object.assign({
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',       // 不让浏览器猜类型（防 XSS 的一个基础项）
    'Referrer-Policy': 'no-referrer'
  }, headers || {});
  /* 客户端说了要 gzip、而且内容够大（>1KB）才压，小响应压了反而多花时间 */
  const wantsGzip = /\bgzip\b/.test(String((res.__req && res.__req.headers['accept-encoding']) || ''));
  if (wantsGzip && Buffer.byteLength(body) > 1024) {
    zlib.gzip(body, (err, zipped) => {
      if (err || !zipped || zipped.length >= Buffer.byteLength(body)) {
        head['Content-Length'] = Buffer.byteLength(body);
        res.writeHead(status, head);
        res.end(body);
        return;
      }
      head['Content-Encoding'] = 'gzip';
      head['Content-Length'] = zipped.length;
      head['Vary'] = 'Accept-Encoding';
      res.writeHead(status, head);
      res.end(zipped);
    });
    return;
  }
  head['Content-Length'] = Buffer.byteLength(body);
  res.writeHead(status, head);
  res.end(body);
}

const ok = (res, data, headers) => sendJson(res, 200, { ok: true, data }, headers);
const fail = (res, status, error, details) => sendJson(res, status, { ok: false, error, details: details || null });

/* ---------------------------------------------------------- 音频转码
   把上传上来的音频（可能是 flac / ape / wma / 甚至是后缀认不出来的）转成 128k 的 mp3：
   iOS 只认 mp3 / m4a / wav / aac，转完就一定能放。失败返回空串（调用方给用户一句人话）。 */
function transcodeAudioToMp3(oldName) {
  const src = path.join(UPLOAD_DIR, oldName);
  let plain = null;
  try { plain = readUploadPlain(src); } catch (e) { plain = null; }
  if (!plain || !plain.length) return '';
  const stamp = Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
  const tmpIn = '/tmp/chris-audio-in-' + stamp;
  const tmpOut = '/tmp/chris-audio-out-' + stamp + '.mp3';
  try { fs.writeFileSync(tmpIn, plain); } catch (e) { return ''; }
  let ok = true;
  try {
    const { execFileSync } = require('child_process');
    execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', tmpIn,
      '-vn', '-b:a', '128k', '-ar', '44100', '-ac', '2', tmpOut], { timeout: 180000 });
  } catch (e) {
    ok = false;
  }
  try { fs.unlinkSync(tmpIn); } catch (e) {}
  if (!ok) { try { fs.unlinkSync(tmpOut); } catch (e) {} return ''; }
  let buf = null;
  try { buf = fs.readFileSync(tmpOut); } catch (e) { buf = null; }
  try { fs.unlinkSync(tmpOut); } catch (e) {}
  if (!buf || !buf.length) return '';
  const name = 'file_' + crypto.randomBytes(8).toString('hex') + '.mp3';
  try { fs.writeFileSync(path.join(UPLOAD_DIR, name), sealUploadBuffer(name, buf)); } catch (e) { return ''; }
  return '/uploads/' + name;
}

/* ---------------------------------------------------------- 音乐曲库
   App「听一听」那一页 + 聊天里的音乐卡片都用这份数据（data/music.json）。
   歌是后台自己上传的（自己录的 / 免版权的），不接任何第三方曲库，免得侵权。 */
function readMusicDb() {
  try {
    const m = readJson(path.join(DATA_DIR, 'music.json'), { tracks: [] });
    if (!m || typeof m !== 'object') return { tracks: [] };
    if (!Array.isArray(m.tracks)) m.tracks = [];
    return m;
  } catch (e) { return { tracks: [] }; }
}
function saveMusicDb(m) {
  const tracks = (Array.isArray(m && m.tracks) ? m.tracks : []).slice(0, 500);
  writeJson(path.join(DATA_DIR, 'music.json'), { tracks });
}
/* 给 App 的列表（字段都保证有值，缺的补空串） */
function musicTracks() {
  return readMusicDb().tracks.map((t) => ({
    id: t.id || '',
    title: t.title || '',
    artist: t.artist || '',
    cover: t.cover || '',
    url: t.url || '',
    lyrics: String(t.lyrics || ''),          // 歌词（LRC 或一行一句；没有就是空串）
    likes: Array.isArray(t.likes) ? t.likes.slice(-200) : [],   // 谁赞过（App 判断我赞过没）
    likeCount: Array.isArray(t.likes) ? t.likes.length : 0,
    shareCount: Number(t.shares) || 0,
    at: Number(t.at) || 0
  })).filter((t) => t.title && t.url);
}

/* ---------------------------------------------------------- 小程序 / 小游戏
   后台「小程序」页加的每一条 = App「发现 → 小程序」里的一张卡；
   App 那一页是个**运行时**（内置浏览器 + wx.* JS 桥），所以后台加新的不用重新出包。
   kind: game = 小游戏（也进「游戏」页），mini = 普通小程序。 */
const DEFAULT_MINIAPPS = [
  { id: 'm01', name: '跳一跳', desc: '按住蓄力，松开起跳', icon: '🕹️', kind: 'game', url: '/games/01-jump-jump/index.html', enabled: true },
  { id: 'm02', name: '2048', desc: '滑动合并相同数字', icon: '🔢', kind: 'game', url: '/games/02-2048/index.html', enabled: true },
  { id: 'm03', name: '飞机大战', desc: '拖动战机，自动开火', icon: '✈️', kind: 'game', url: '/games/03-plane-war/index.html', enabled: true },
  { id: 'm04', name: '贪吃蛇', desc: '滑动操控，越吃越长', icon: '🐍', kind: 'game', url: '/games/04-snake/index.html', enabled: true }
];
function readMiniApps() {
  const cfg = readJson(path.join(DATA_DIR, 'miniapps.json'), null);
  if (!cfg || !Array.isArray(cfg.items)) return { items: DEFAULT_MINIAPPS.slice() };
  return cfg;
}
function saveMiniApps(cfg) {
  writeJson(path.join(DATA_DIR, 'miniapps.json'), { items: (cfg.items || []).slice(0, 200) });
}
/** 给 App 的列表：字段都补全，url 必须是 /… 或 http(s) */
function miniAppList(onlyKind) {
  return (readMiniApps().items || []).filter((x) => x && x.enabled !== false)
    .filter((x) => !onlyKind || String(x.kind || 'mini') === onlyKind)
    .map((x) => ({
      id: String(x.id || ''),
      name: String(x.name || '小程序').slice(0, 20),
      desc: String(x.desc || '').slice(0, 40),
      icon: String(x.icon || '🧩').slice(0, 8),
      kind: String(x.kind || 'mini'),
      url: String(x.url || ''),
      color: String(x.color || ''),
      cover: String(x.cover || ''),
      group: String(x.group || '').slice(0, 16),
      action: String(x.action || '立即玩').slice(0, 6)
    })).filter((x) => x.url);
}

/* ---------------------------------------------------------- 小游戏分数（好友排名用）
   每个游戏给每个人记一条**最高分**（只涨不跌）；排行榜就是「我 + 我的好友」按分排。 */
/* 「我正在听」：谁在听哪首歌（好友的「朋友推荐」用） */
/* 「棋牌大厅」的桌子：一桌 4 个位（四国军棋：东南西北各一家） */
const TABLES_FILE = 'game-tables.json';
function readTables() {
  const j = readJson(path.join(DATA_DIR, TABLES_FILE), { tables: [] });
  if (!j || typeof j !== 'object') return { tables: [] };
  if (!Array.isArray(j.tables)) j.tables = [];
  /* 超过 2 小时没动静的清掉，别让大厅越攒越多 */
  const now = Date.now();
  j.tables = j.tables.filter((t) => t && (now - Number(t.at || 0)) < 2 * 3600 * 1000);
  return j;
}
function saveTables(j) { writeJson(path.join(DATA_DIR, TABLES_FILE), { tables: (j.tables || []).slice(0, 200) }); }
function newTableCode() {
  for (let i = 0; i < 50; i++) {
    const c = String(Math.floor(1000 + Math.random() * 9000));
    const j = readTables();
    if (!j.tables.some((t) => t.code === c)) return c;
  }
  return String(Date.now()).slice(-4);
}
function tablePublic(t, meId) {
  return {
    code: t.code,
    game: t.game || 'g09',
    host: t.host || '',
    started: !!t.started,
    seats: (t.seats || []).map((x) => x ? {
      id: x.id, name: x.name || '玩家', avatar: x.avatar || '', mine: x.id === meId
    } : null),
    seated: (t.seats || []).filter(Boolean).length
  };
}

function readMusicNow() {
  const j = readJson(path.join(DATA_DIR, 'music-now.json'), { users: {} });
  if (!j || typeof j !== 'object') return { users: {} };
  if (!j.users || typeof j.users !== 'object') j.users = {};
  return j;
}
function saveMusicNow(j) {
  const users = j.users || {};
  const ids = Object.keys(users);
  /* 只留最近 500 条，别让这个文件无限长大 */
  if (ids.length > 500) {
    ids.sort((a, b) => (Number(users[b].at) || 0) - (Number(users[a].at) || 0))
      .slice(500).forEach((k) => { delete users[k]; });
  }
  writeJson(path.join(DATA_DIR, 'music-now.json'), { users: users });
}

function readGameScores() {
  const j = readJson(path.join(DATA_DIR, 'game-scores.json'), { scores: {} });
  if (!j || typeof j !== 'object') return { scores: {} };
  if (!j.scores || typeof j.scores !== 'object') j.scores = {};
  return j;
}
function saveGameScores(j) { writeJson(path.join(DATA_DIR, 'game-scores.json'), { scores: j.scores || {} }); }

function readBody(req) {
  /* 同一个请求可能被两个分支先后读（比如 /me/status 既是「结束我的状态」又是「改在线状态」），
     缓存一下，第二次读直接拿同一份，不会因为流已经读完而拿到空对象。 */
  if (req.__bodyPromise) return req.__bodyPromise;
  req.__bodyPromise = new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(Object.assign(new Error('请求体过大'), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      if (!chunks.length) return resolve({});
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch (err) { reject(Object.assign(new Error('JSON 解析失败'), { status: 400 })); }
    });
    req.on('error', reject);
  });
  return req.__bodyPromise;
}

/* -------------------------------------------------------------- 管理后台 */

function dirSize(dir) {
  let total = 0;
  const walk = (d) => {
    let entries = [];
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch (err) { return; }
    entries.forEach((entry) => {
      const p = path.join(d, entry.name);
      if (entry.isDirectory()) walk(p);
      else { try { total += fs.statSync(p).size; } catch (err) { /* 忽略 */ } }
    });
  };
  walk(dir);
  return total;
}

function closeUserConnections(userId) {
  const set = connections.get(userId);
  if (!set) return;
  set.forEach((socket) => { try { socket.end(); } catch (err) { /* 忽略 */ } });
  connections.delete(userId);
  notifyPresence(userId, false);
}

/* ================================================================
   封禁 / 解封：一处收口，保证每种入口封出来都一样有效
   以前只在后台「用户账号」里改了个字段，被封的人手里那台手机
   还留着有效登录态：长连接断了会被踢，但刷新一下照样能看会话、
   看通讯录、看朋友圈，等于没封住。现在封禁要做三件事：
     ① banned 标记（登录接口、发消息、长连接都会拦）
     ② tokenVersion +1 → 该账号所有设备上的登录态立刻作废
     ③ 关掉正在连的长连接，并通知好友「他下线了」
   ================================================================ */
function setUserBanned(u, banned, reason, by) {
  if (!u) return false;
  const on = !!banned;
  const was = !!u.banned;
  u.banned = on;
  if (on) {
    u.banReason = str(reason, 100) || u.banReason || '违规';
    u.bannedAt = now();
    u.bannedBy = by || '';
    /* 登录令牌里带的是签发时的 tokenVersion，这里 +1 之后
       对方手机上的 token 立刻对不上，所有接口都会 401。 */
    u.tokenVersion = (Number(u.tokenVersion) || 0) + 1;
    closeUserConnections(u.id);
  } else {
    u.banReason = '';
    u.bannedAt = 0;
    u.bannedBy = '';
  }
  saveUsers();
  return was !== on;      // 状态真的变了才返回 true（给审计用）
}

/* 统一的封禁提示：带上后台填的原因，用户在登录页就知道为什么进不去 */
function banMsg(u) {
  const why = u && u.banReason ? '（' + u.banReason + '）' : '';
  return '该账号已被管理员禁用' + why + '，可在登录页点「自助解封」用身份证解封';
}

/* CHRIS_FREEZE_V1 「自己冻结账号」的提示（和封禁区分开：冻结是本人/管理员临时锁，
   登录页点「解冻账号」用账号密码（+ 实名身份证号）就能自己解开） */
function frozenMsg(u) {
  const why = u && u.frozenReason ? '（' + u.frozenReason + '）' : '';
  return '该账号已被冻结' + why + '，可在登录页点「解冻账号」自助解冻';
}

/* ================================================================
   身份证自助解封
   被封 · 号的人可以在登录页点「自助解封」，填账号密码 + 身份证号；
   号码要能过下面这套校验（18 位、省份、生日、校验位），
   通过就把账号解封并直接登录。同一张身份证只能绑一个账号，
   所以随便编一个号码是解不开别人的号的。
   ================================================================ */
const ID_WEIGHTS = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
const ID_CHECK = ['1', '0', 'X', '9', '8', '7', '6', '5', '4', '3', '2'];
const ID_PROVINCE = new Set(['11', '12', '13', '14', '15', '21', '22', '23', '31', '32', '33', '34', '35',
  '36', '37', '41', '42', '43', '44', '45', '46', '50', '51', '52', '53', '54', '61', '62', '63', '64',
  '65', '71', '81', '82', '91']);
const normalizeIdCard = (v) => String(v == null ? '' : v).trim().toUpperCase().replace(/[\s-]/g, '');
function isValidIdCard(raw) {
  const id = normalizeIdCard(raw);
  if (!/^\d{17}[\dX]$/.test(id)) return false;              // 18 位，最后一位可以是 X
  if (!ID_PROVINCE.has(id.slice(0, 2))) return false;       // 省份代码
  const y = Number(id.slice(6, 10));
  const m = Number(id.slice(10, 12));
  const d = Number(id.slice(12, 14));
  if (y < 1900 || y > new Date().getFullYear()) return false;
  const dt = new Date(y, m - 1, d);
  if (dt.getFullYear() !== y || dt.getMonth() !== m - 1 || dt.getDate() !== d) return false;   // 生日得真实存在
  if (dt.getTime() > Date.now()) return false;
  let sum = 0;
  for (let i = 0; i < 17; i += 1) sum += Number(id[i]) * ID_WEIGHTS[i];
  return ID_CHECK[sum % 11] === id[17];                     // 校验位
}
const maskIdCard = (id) => id.slice(0, 6) + '********' + id.slice(14);
/* 身份证指纹：带密钥的 HMAC —— 以前是无盐 sha256，拖库后能把身份证号枚举出来 */
const idCardHash = (id) => crypto.createHmac('sha256', String(db.secret || 'chris'))
  .update('idcard:' + String(id == null ? '' : id).trim()).digest('hex');

/* 未实名的账号能不能碰钱？—— 和微信一样：**聊天不受影响**，但转账/红包/收付款/零钱
   这些「钱」的动作必须先实名。返回 true 表示已经拦下（调用方直接 return 即可）。
   文案照着微信的口气：「根据国家规定，请先完成实名认证」。 */
function blockedByRealName(res, user) {
  try {
    if (!user) return false;
    if (user.realName && user.idCardHash) return false;      // 已经实名
    fail(res, 403, '根据国家规定，请先完成实名认证后再使用（我 → 设置 → 实名认证）', { needRealName: true });
    return true;
  } catch (e) { return false; }
}

/* 昵称规范（照微信来）：返回 '' 表示通过，否则返回给用户看的原因。
   ① 1~16 个「字符」（一个汉字、一个 emoji 都算 1 个）
   ② 首尾不能有空格、不能只有空格
   ③ 不允许 < > " ' / \ 这类符号（微信也不让用，顺带防注入/排版错乱）
   ④ 不能含敏感词，也不能冒用「微信 / 官方 / 客服 / 管理员」这类身份 */
function checkNickname(raw) {
  const s = String(raw == null ? '' : raw);
  const t = s.trim();
  if (!t) return '昵称不能为空';
  if (t !== s) return '昵称前后不能有空格';
  if (Array.from(t).length > 16) return '昵称最长 16 个字符';
  if (/[<>"'/\\]/.test(t)) return '昵称里有不允许的符号（< > " \' / \\）';
  if (/[\u0000-\u001f\u007f]/.test(t)) return '昵称里有不允许的字符';
  if (!/[\u4e00-\u9fa5A-Za-z0-9]/.test(t)) return '昵称至少要有一个汉字、字母或数字';
  if (sensitiveHit(t)) return '昵称里含有不允许的词语';
  if (/微信|weixin|wechat|腾讯|tencent|官方|客服|管理员|系统消息|root|admin/i.test(t)) {
    return '昵称不能冒用官方、客服这类身份';
  }
  return '';
}

/** 手机号绑定后一年内只能换一次（和微信一样）。返回还要等几天，0 = 可以换 */
function phoneChangeWaitDays(user) {
  const t = user && user.phoneChangedAt ? Date.parse(user.phoneChangedAt) : 0;
  if (!t || isNaN(t)) return 0;
  const days = 365 - Math.floor((Date.now() - t) / 86400000);
  return days > 0 ? days : 0;
}

/* 省 / 市（地区选择用：和微信一样是两个滚轮，上下滑着选）。列到地级市，省得拉一个大文件。 */
const REGIONS = [
  ['北京', '北京'], ['天津', '天津'], ['上海', '上海'], ['重庆', '重庆'],
  ['河北', '石家庄 唐山 秦皇岛 邯郸 邢台 保定 张家口 承德 沧州 廊坊 衡水'],
  ['山西', '太原 大同 阳泉 长治 晋城 朔州 晋中 运城 忻州 临汾 吕梁'],
  ['内蒙古', '呼和浩特 包头 乌海 赤峰 通辽 鄂尔多斯 呼伦贝尔 巴彦淖尔 乌兰察布 兴安盟 锡林郭勒盟 阿拉善盟'],
  ['辽宁', '沈阳 大连 鞍山 抚顺 本溪 丹东 锦州 营口 阜新 辽阳 盘锦 铁岭 朝阳 葫芦岛'],
  ['吉林', '长春 吉林 四平 辽源 通化 白山 松原 白城 延边'],
  ['黑龙江', '哈尔滨 齐齐哈尔 鸡西 鹤岗 双鸭山 大庆 伊春 佳木斯 七台河 牡丹江 黑河 绥化 大兴安岭'],
  ['江苏', '南京 无锡 徐州 常州 苏州 南通 连云港 淮安 盐城 扬州 镇江 泰州 宿迁'],
  ['浙江', '杭州 宁波 温州 嘉兴 湖州 绍兴 金华 衢州 舟山 台州 丽水'],
  ['安徽', '合肥 芜湖 蚌埠 淮南 马鞍山 淮北 铜陵 安庆 黄山 滁州 阜阳 宿州 六安 亳州 池州 宣城'],
  ['福建', '福州 厦门 莆田 三明 泉州 漳州 南平 龙岩 宁德'],
  ['江西', '南昌 景德镇 萍乡 九江 新余 鹰潭 赣州 吉安 宜春 抚州 上饶'],
  ['山东', '济南 青岛 淄博 枣庄 东营 烟台 潍坊 济宁 泰安 威海 日照 临沂 德州 聊城 滨州 菏泽'],
  ['河南', '郑州 开封 洛阳 平顶山 安阳 鹤壁 新乡 焦作 濮阳 许昌 漯河 三门峡 南阳 商丘 信阳 周口 驻马店 济源'],
  ['湖北', '武汉 黄石 十堰 宜昌 襄阳 鄂州 荆门 孝感 荆州 黄冈 咸宁 随州 恩施 仙桃 潜江 天门 神农架'],
  ['湖南', '长沙 株洲 湘潭 衡阳 邵阳 岳阳 常德 张家界 益阳 郴州 永州 怀化 娄底 湘西'],
  ['广东', '广州 韶关 深圳 珠海 汕头 佛山 江门 湛江 茂名 肇庆 惠州 梅州 汕尾 河源 阳江 清远 东莞 中山 潮州 揭阳 云浮'],
  ['广西', '南宁 柳州 桂林 梧州 北海 防城港 钦州 贵港 玉林 百色 贺州 河池 来宾 崇左'],
  ['海南', '海口 三亚 三沙 儋州'],
  ['四川', '成都 自贡 攀枝花 泸州 德阳 绵阳 广元 遂宁 内江 乐山 南充 眉山 宜宾 广安 达州 雅安 巴中 资阳 阿坝 甘孜 凉山'],
  ['贵州', '贵阳 六盘水 遵义 安顺 毕节 铜仁 黔西南 黔东南 黔南'],
  ['云南', '昆明 曲靖 玉溪 保山 昭通 丽江 普洱 临沧 楚雄 红河 文山 西双版纳 大理 德宏 怒江 迪庆'],
  ['西藏', '拉萨 日喀则 昌都 林芝 山南 那曲 阿里'],
  ['陕西', '西安 铜川 宝鸡 咸阳 渭南 延安 汉中 榆林 安康 商洛'],
  ['甘肃', '兰州 嘉峪关 金昌 白银 天水 武威 张掖 平凉 酒泉 庆阳 定西 陇南 临夏 甘南'],
  ['青海', '西宁 海东 海北 黄南 海南 果洛 玉树 海西'],
  ['宁夏', '银川 石嘴山 吴忠 固原 中卫'],
  ['新疆', '乌鲁木齐 克拉玛依 吐鲁番 哈密 昌吉 博尔塔拉 巴音郭楞 阿克苏 克孜勒苏 喀什 和田 伊犁 塔城 阿勒泰 石河子'],
  ['台湾', '台北 新北 桃园 台中 台南 高雄 基隆 新竹 嘉义'],
  ['香港', '香港'], ['澳门', '澳门']
].map((r) => [r[0], r[1].split(' ')]);
const unbanHits = new Map();
function unbanRateAllow(ip) {
  const t = Date.now();
  const r = unbanHits.get(ip);
  if (!r || t - r.t > 10 * 60 * 1000) { unbanHits.set(ip, { t, n: 1 }); return true; }
  r.n += 1;
  if (unbanHits.size > 5000) unbanHits.clear();
  return r.n <= 20;                                          // 10 分钟最多试 20 次，防拿号码库猜号
}

/* 实名认证：同一台设备 10 分钟最多提交 10 次（防拿号码库试） */
const realNameHits = new Map();
function realNameRateAllow(key) {
  const t = Date.now();
  const r = realNameHits.get(key);
  if (!r || t - r.t > 10 * 60 * 1000) { realNameHits.set(key, { t, n: 1 }); return true; }
  r.n += 1;
  if (realNameHits.size > 5000) realNameHits.clear();
  return r.n <= 10;
}

const bottleHits = new Map();
function bottleRateAllow(key) {          // CHRIS_BOTTLE_V1：同一账号 10 分钟最多扔/捞 30 次
  const t = Date.now();
  const r = bottleHits.get(key);
  if (!r || t - r.t > 10 * 60 * 1000) { bottleHits.set(key, { t, n: 1 }); return true; }
  r.n += 1;
  if (bottleHits.size > 5000) bottleHits.clear();
  return r.n <= 30;
}

function adminStats() {
  const chats = db.chats;
  return {
    users: db.users.length,
    banned: db.users.filter((u) => u.banned).length,
    online: onlineUserIds().length,
    friends: db.friendships.filter((f) => f.status === 'accepted').length,
    pendingRequests: db.friendships.filter((f) => f.status === 'pending').length,
    chats: chats.length,
    directChats: chats.filter((c) => c.type === 'direct').length,
    groupChats: chats.filter((c) => c.type === 'group').length,
    messages: chats.reduce((sum, c) => sum + loadMessages(c.id).length, 0),
    moments: db.moments.length,
    momentLikes: db.moments.reduce((s, m) => s + (m.likes || []).length, 0),
    momentComments: db.moments.reduce((s, m) => s + (m.comments || []).length, 0),
    announcements: db.announcements.length,
    storageBytes: dirSize(DATA_DIR)
  };
}


/* ==================== 新版后台：参考「一对一视频社交」后台的结构 ==================== */

/** 后台左侧菜单（照参考后台的分组，路径换成我们自己的 dataset 名） */
const ADMIN_NAV = [
  { key: 'dash', text: '数据总览', icon: 'dashboard' },
  { text: '设置', children: [
    { key: 'site', text: '网站信息' },
    { key: 'ui', text: '界面图标' },
    { key: 'font', text: '字体字号' },
    { key: 'theme', text: '界面配色' },
    { key: 'chatbg', text: '聊天背景' },
    { key: 'ice', text: '通话服务器' },
    { key: 'configpri', text: '私密设置' },
    { key: 'slide', text: '幻灯片管理' },
    { key: 'guide', text: '引导页' },
    { key: 'recommend', text: '推荐设置' },
    { key: 'system', text: '系统信息' }
  ] },
  { text: '用户管理', children: [
    { key: 'users', text: '本站用户' },
    { key: 'auth', text: '实名认证管理' },
    { key: 'authorauth', text: '主播认证管理' }
  ] },
  { text: '用户举报', children: [
    { key: 'reportclass', text: '举报分类' },
    { key: 'report', text: '举报列表' }
  ] },
  { text: '相册管理', children: [
    { key: 'photofee', text: '私密价格' },
    { key: 'photo', text: '相册列表' }
  ] },
  { text: '直播管理', children: [
    { key: 'liveclass', text: '分类列表' },
    { key: 'liveban', text: '禁播管理' },
    { key: 'liveshut', text: '禁言管理' },
    { key: 'livekick', text: '踢人管理' },
    { key: 'liveing', text: '直播列表' },
    { key: 'monitorz', text: '直播监控' },
    { key: 'liverecord', text: '直播记录' }
  ] },
  { text: '动态管理', children: [
    { key: 'dynamicreportclass', text: '举报类型' },
    { key: 'dynamicreport', text: '举报列表' },
    { key: 'dynamicpass', text: '审核通过列表' },
    { key: 'dynamic', text: '等待审核列表' },
    { key: 'dynamicnopass', text: '未通过列表' },
    { key: 'dynamiclower', text: '下架列表' }
  ] },
  { text: '视频管理', children: [
    { key: 'videofee', text: '私密价格' },
    { key: 'video', text: '视频列表' },
    { key: 'videoreportclass', text: '举报分类' },
    { key: 'videoreport', text: '举报列表' }
  ] },
  { text: '私聊管理', children: [
    { key: 'feevideo', text: '视频价格' },
    { key: 'feevoice', text: '语音价格' }
  ] },
  { text: '鉴黄管理', children: [
    { key: 'reflectshot', text: '直播截图' },
    { key: 'reflectyellow', text: '鉴黄记录' },
    { key: 'reflectblock', text: '封禁列表' }
  ] },
  { key: 'calls', text: '通话记录' },
  { key: 'callmonitor', text: '通话监控' },
  { text: '财务管理', children: [
    { key: 'voterecord', text: '云票记录' },
    { key: 'chargerule', text: '充值规则' },
    { key: 'charge', text: '充值记录' },
    { key: 'manual', text: '手动充值' },
    { key: 'cash', text: '提现记录' },
    { key: 'coinrecord', text: '消费记录' }
  ] },
  { text: '礼物管理', children: [ { key: 'gift', text: '礼物列表' } ] },
  { text: '等级管理', children: [
    { key: 'level', text: '经验等级' },
    { key: 'levelanchor', text: '主播等级' }
  ] },
  { text: '标签管理', children: [
    { key: 'label', text: '形象标签' },
    { key: 'evaluate', text: '评价标签' }
  ] },
  { text: '邀请奖励', children: [
    { key: 'agent', text: '邀请关系' },
    { key: 'agentprofit', text: '邀请收益' }
  ] },
  { text: '公会管理', children: [
    { key: 'family', text: '公会列表' },
    { key: 'familyuser', text: '成员管理' },
    { key: 'divideapply', text: '分成申请列表' }
  ] },
  { text: 'VIP管理', children: [
    { key: 'vip', text: 'VIP列表' },
    { key: 'vipuser', text: 'VIP用户' },
    { key: 'viporder', text: 'VIP订单' }
  ] },
  { text: '内容管理', children: [ { key: 'page', text: '页面管理' }, { key: 'chats', text: '会话管理' }, { key: 'broadcast', text: '系统公告' } ] }
];

/** 通用数据表：没有专门存储的模块统一放这里（礼物 / 等级 / 标签 / 充值规则 …） */
const EMPTY_TABLES = {
  gift: { cols: ['ID', '名称', '图标', '价格', '动效', '排序', '状态'], rows: [] },
  level: { cols: ['ID', '等级', '经验值', '图标', '排序'], rows: [] },
  levelanchor: { cols: ['ID', '等级', '经验值', '分成比例', '排序'], rows: [] },
  label: { cols: ['ID', '名称', '排序'], rows: [] },
  evaluate: { cols: ['ID', '名称', '排序'], rows: [] },
  reportclass: { cols: ['ID', '名称', '英文名', '排序'], rows: [] },
  dynamicreportclass: { cols: ['ID', '名称', '英文名', '排序'], rows: [] },
  videoreportclass: { cols: ['ID', '名称', '英文名', '排序'], rows: [] },
  chargerule: { cols: ['ID', '充值金额', '到账云票', '赠送', '排序'], rows: [] },
  photofee: { cols: ['ID', '价格', '等级', '排序'], rows: [] },
  videofee: { cols: ['ID', '价格', '等级', '排序'], rows: [] },
  feevideo: { cols: ['ID', '价格/分', '等级', '排序'], rows: [] },
  feevoice: { cols: ['ID', '价格/分', '等级', '排序'], rows: [] },
  liveclass: { cols: ['ID', '名称', '排序'], rows: [] },
  recommend: { cols: ['ID', '推荐位', '用户', '排序'], rows: [] },
  slide: { cols: ['ID', '封面', '链接', '排序'], rows: [] },
  guide: { cols: ['ID', '类型', '图片/视频', '排序'], rows: [] },
  page: { cols: ['ID', '标题', '标识', '更新时间'], rows: [] },
  vip: { cols: ['ID', '名称', '价格', '天数', '排序'], rows: [] }
};

function tableStore(name) {
  if (!db.tables) db.tables = {};
  if (!db.tables[name]) db.tables[name] = JSON.parse(JSON.stringify(EMPTY_TABLES[name] || { cols: ['ID', '名称'], rows: [] }));
  return db.tables[name];
}

function saveTables() {
  try { fs.writeFileSync(path.join(DATA_DIR, 'tables.json'), JSON.stringify(db.tables || {}, null, 2), 'utf8'); } catch (err) { /* 忽略 */ }
}

/** 数据总览：照参考后台的 5 组卡片，用我们自己的真实数据算 */
function dashboardStats() {
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const yest = new Date(today.getTime() - 86400000);
  const dayOf = (t) => { const d = new Date(t); d.setHours(0, 0, 0, 0); return d.getTime(); };
  const usersToday = db.users.filter((u) => dayOf(u.createdAt || 0) === today.getTime()).length;
  const usersYest = db.users.filter((u) => dayOf(u.createdAt || 0) === yest.getTime()).length;
  // 通话：从聊天里的系统消息里统计（「通话结束 · 时长 m:ss」「视频通话结束 · 时长 m:ss」）
  let calls = [], voiceMin = 0, videoMin = 0, callsToday = 0, callsYest = 0;
  try {
    const files = fs.readdirSync(path.join(DATA_DIR, 'messages'));
    files.forEach((f) => {
      const lines = fs.readFileSync(path.join(DATA_DIR, 'messages', f), 'utf8').split('\n').filter(Boolean);
      lines.forEach((line) => {
        let m; try { m = JSON.parse(line); } catch (e) { return; }
        if (m.kind !== 'system' || !/通话/.test(String(m.content || ''))) return;
        const video = /视频/.test(m.content);
        const mm = String(m.content).match(/(\d+):(\d\d)/);
        const mins = mm ? (Number(mm[1]) * 60 + Number(mm[2])) / 60 : 0;
        const rec = { chatId: f.replace(/\.jsonl$/, ''), at: m.createdAt, type: video ? '视频通话' : '语音通话', content: m.content, mins: Math.round(mins * 100) / 100 };
        calls.push(rec);
        if (!/未接听|已取消|已拒绝|无应答|对方不在线|忙线/.test(m.content)) { if (video) videoMin += mins; else voiceMin += mins; }
        if (dayOf(m.createdAt) === today.getTime()) callsToday++;
        if (dayOf(m.createdAt) === yest.getTime()) callsYest++;
      });
    });
  } catch (err) { /* 忽略 */ }
  calls.sort((a, b) => String(b.at).localeCompare(String(a.at)));
  const moments = (db.moments || []);
  const pending = moments.filter((m) => m.status === 'pending').length;
  const pct = (cur, prev) => prev > 0 ? Math.round((cur - prev) / prev * 100) + '%' : (cur > 0 ? '+100%' : '0%');
  return {
    groups: [
      { title: '用户统计', items: [
        { label: '今日注册人数', value: usersToday, sub: '较于前一日：' + pct(usersToday, usersYest), sub2: '昨日：' + usersYest, total: '平台总注册人数：' + db.users.length }
      ] },
      { title: '审核统计', items: [
        { label: '动态未审核数', value: pending, sub: '较于前一日：0%', sub2: '昨日：0', total: '总动态数：' + moments.length }
      ] },
      { title: '通话统计', items: [
        { label: '今日通话数', value: callsToday, sub: '较于前一日：' + pct(callsToday, callsYest), sub2: '昨日：' + callsYest, total: '通话记录总数：' + calls.length },
        { label: '语音通话时间（分钟）', value: Math.round(voiceMin), sub: '', sub2: '', total: '语音通话总时间：' + Math.round(voiceMin) },
        { label: '视频通话时间（分钟）', value: Math.round(videoMin), sub: '', sub2: '', total: '视频通话总时间：' + Math.round(videoMin) },
        { label: '总通话时间（分钟）', value: Math.round(voiceMin + videoMin), sub: '', sub2: '', total: '通话时间总数：' + Math.round(voiceMin + videoMin) }
      ] }
    ],
    recentCalls: calls.slice(0, 10),
    allCalls: calls
  };
}

/** 通用列表：每个 dataset 返回 { cols, rows, total } */
function datasetRows(name, query) {
  const q = (k) => String(query.get(k) || '').trim();
  const page = Math.max(1, Number(query.get('page')) || 1);
  const pageSize = Math.min(200, Number(query.get('pageSize')) || 30);
  let cols = [], rows = [];
  if (name === 'users') {
    cols = ['ID', '用户名', '昵称', '手机号', '注册时间', '状态', '操作'];
    let list = db.users.slice().sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    if (q('uid')) list = list.filter((u) => String(u.id).includes(q('uid')));
    if (q('keyword')) { const k = q('keyword').toLowerCase(); list = list.filter((u) => (u.username || '').toLowerCase().includes(k) || (u.nickname || '').toLowerCase().includes(k) || String(u.phone || '').includes(k)); }
    if (q('status') === 'banned') list = list.filter((u) => u.banned);
    if (q('status') === 'ok') list = list.filter((u) => !u.banned);
    rows = list.map((u) => ({ id: u.id, cells: [u.id, u.username, u.nickname, u.phone || '-', String(u.createdAt || '').slice(0, 16).replace('T', ' '), u.banned ? '已封禁' : '正常', ''], raw: { id: u.id, username: u.username, nickname: u.nickname, banned: !!u.banned } }));
    return { cols, rows, total: list.length, page, pageSize };
  }
  if (name === 'calls' || name === 'callmonitor') {
    cols = ['ID', '通话类型', '状态', '会话', '时长', '时间'];
    let list = (dashboardStats().allCalls || []);
    if (q('type')) list = list.filter((r) => (q('type') === 'video' ? r.type === '视频通话' : r.type === '语音通话'));
    if (q('status') && q('status') !== 'all') list = list.filter((r) => q('status') === 'end' ? !/未接听|已取消|已拒绝/.test(r.content) : /未接听|已取消|已拒绝/.test(r.content));
    rows = list.map((r, idx) => ({ id: idx + 1, cells: [idx + 1, r.type, /未接听|已取消|已拒绝|不在线|忙线/.test(r.content) ? '未接通' : '通话结束', r.chatId, r.mins + ' 分钟', String(r.at).slice(0, 19).replace('T', ' ')], raw: r }));
    return { cols, rows, total: list.length, page, pageSize };
  }
  if (name && name.indexOf('dynamic') === 0) {
    cols = ['ID', '用户', '内容', '图片数', '点赞', '评论', '发布时间', '状态', '操作'];
    const all = (db.moments || []);
    const want = name === 'dynamic' ? 'pending' : (name === 'dynamicpass' ? 'passed' : (name === 'dynamicnopass' ? 'rejected' : (name === 'dynamiclower' ? 'lower' : null)));
    let list = want ? all.filter((m) => (m.status || 'passed') === want) : all;
    if (name === 'dynamic') list = all.filter((m) => m.status === 'pending');
    rows = list.map((m) => { const u = findUser(m.authorId) || {}; return { id: m.id, cells: [m.id, (u.nickname || '未知') + ' (' + m.authorId + ')', String(m.content || '').slice(0, 40) || '(图片)', (m.images || []).length, (m.likes || []).length, (m.comments || []).length, String(m.createdAt || '').slice(0, 16).replace('T', ' '), m.status === 'pending' ? '待审核' : (m.status === 'rejected' ? '未通过' : (m.status === 'lower' ? '已下架' : '已通过')), ''], raw: m }; });
    return { cols, rows, total: list.length, page, pageSize };
  }
  if (name === 'site' || name === 'configpri' || name === 'guide' || name === 'ice' || name === 'ui') {
    return { cols: [], rows: [], total: 0, settings: name };
  }
  const t = tableStore(name);
  const list = (t.rows || []);
  rows = list.map((r, idx) => ({ id: r.id || idx + 1, cells: (t.cols || []).map((c, ci) => (ci === 0 ? (r.id || idx + 1) : (r.cells ? r.cells[ci] : ''))), raw: r }));
  return { cols: t.cols, rows, total: list.length, page, pageSize };
}

function adminAct(body) {
  const name = str(body.dataset, 40);
  const action = str(body.action, 20);
  const id = str(body.id, 60);
  if (name === 'users') {
    const u = findUser(id);
    if (!u) return { error: '用户不存在', status: 404 };
        if (action === 'ban') { setUserBanned(u, true, '旧版后台封禁', '旧版后台'); }
        else if (action === 'unban') { setUserBanned(u, false, '', '旧版后台'); }
    else if (action === 'delete') { db.users = db.users.filter((x) => x.id !== id); saveUsers(); }
    else if (action === 'edit') { if (body.nickname !== undefined) u.nickname = str(body.nickname, 24); if (body.phone !== undefined) u.phone = str(body.phone, 20); saveUsers(); }
    else return { error: '不支持的操作', status: 400 };
    return { ok: true, user: publicUser(u) };
  }
  if (name === 'dynamic' || name === 'dynamicpass' || name === 'dynamicnopass' || name === 'dynamiclower') {
    const m = (db.moments || []).find((x) => x.id === id);
    if (!m) return { error: '动态不存在', status: 404 };
    if (action === 'pass') m.status = 'passed';
    else if (action === 'reject') m.status = 'rejected';
    else if (action === 'lower') m.status = 'lower';
    else if (action === 'delete') db.moments = (db.moments || []).filter((x) => x.id !== id);
    else return { error: '不支持的操作', status: 400 };
    saveMoments();
    return { ok: true };
  }
  const t = tableStore(name);
  if (action === 'delete') { t.rows = (t.rows || []).filter((r) => String(r.id) !== String(id)); saveTables(); return { ok: true }; }
  if (action === 'save') {
    const cells = Array.isArray(body.cells) ? body.cells.map((x) => str(x, 200)) : [];
    if (id) { const r = (t.rows || []).find((x) => String(x.id) === String(id)); if (r) r.cells = cells; }
    else { t.rows = t.rows || []; t.rows.push({ id: (t.rows.length ? Math.max(...t.rows.map((r) => Number(r.id) || 0)) : 0) + 1, cells }); }
    saveTables();
    return { ok: true };
  }
  return { error: '不支持的模块或操作', status: 400 };
}

/** 保存 dataURL 上传的文件，返回 { url, name, bytes, image } 或 { error, status } */
/* ============================================================ 图片体检
   图片木马的几种常见玩法，全在这里拦：
     ① 照片里塞 GPS/设备信息（EXIF）→ 存之前把元数据剔掉
     ② 图片炸弹（几百字节声明成几万×几万，客户端一解码就爆内存）→ 看分辨率，太大直接拒
     ③ 畸形图（截断 / 全零 / 魔数不对）→ 会让 App 里的解码器崩，直接拒
   ------------------------------------------------------------------ */
/* 图片炸弹防线：超过下面这两个数直接拒；介于之间的大图会自动缩小到 2560 长边再存。
   参考：1200 万像素解码约 48MB 内存，4000 万像素要 160MB —— 手机上就是直接被杀进程。 */
const IMG_MAX_PIXELS = 40 * 1000 * 1000;   // 硬上限 4000 万像素（再大直接拒）
const IMG_MAX_SIDE = 12000;                // 硬上限单边 12000
const IMG_SHRINK_PIXELS = 3 * 1000 * 1000; // 超过 300 万像素就自动缩小
const IMG_SHRINK_SIDE = 2560;              // 缩到长边 2560
const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** 读出图片的分辨率（读不出来就返回 null） */
function imageSizeOf(buf, mime) {
  try {
    if (mime === 'image/png') {
      if (buf.length < 24 || !buf.slice(0, 8).equals(PNG_SIG)) return null;
      return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
    }
    if (mime === 'image/gif') {
      if (buf.length < 10) return null;
      return { w: buf.readUInt16LE(6), h: buf.readUInt16LE(8) };
    }
    if (mime === 'image/jpeg') {
      let i = 2;
      while (i < buf.length - 8) {
        if (buf[i] !== 0xff) { i += 1; continue; }
        const mk = buf[i + 1];
        if (mk === 0xd8 || (mk >= 0xd0 && mk <= 0xd9) || mk === 0x01) { i += 2; continue; }
        const len = buf.readUInt16BE(i + 2);
        const isSOF = (mk >= 0xc0 && mk <= 0xc3) || (mk >= 0xc5 && mk <= 0xc7) ||
          (mk >= 0xc9 && mk <= 0xcb) || (mk >= 0xcd && mk <= 0xcf);
        if (isSOF) return { h: buf.readUInt16BE(i + 5), w: buf.readUInt16BE(i + 7) };
        if (mk === 0xda || len < 2) break;
        i += 2 + len;
      }
      return null;
    }
    if (mime === 'image/webp') {
      if (buf.length < 30 || buf.slice(0, 4).toString('latin1') !== 'RIFF') return null;
      const fourcc = buf.slice(12, 16).toString('latin1');
      if (fourcc === 'VP8X') {
        const w = 1 + (buf[24] | (buf[25] << 8) | (buf[26] << 16));
        const h = 1 + (buf[27] | (buf[28] << 8) | (buf[29] << 16));
        return { w, h };
      }
      if (fourcc === 'VP8 ') {
        return { w: buf.readUInt16LE(26) & 0x3fff, h: buf.readUInt16LE(28) & 0x3fff };
      }
      if (fourcc === 'VP8L') {
        const b = buf.readUInt32LE(21);
        return { w: (b & 0x3fff) + 1, h: ((b >> 14) & 0x3fff) + 1 };
      }
      return null;
    }
    if (mime === 'image/bmp') {
      if (buf.length < 30 || buf[0] !== 0x42 || buf[1] !== 0x4d) return null;
      return { w: Math.abs(buf.readInt32LE(18)), h: Math.abs(buf.readInt32LE(22)) };
    }
  } catch (err) { return null; }
  return null;
}

/* 这几种图我们现在不解析结构（iPhone 的 HEIC、TIFF），
   允许上传但一样要走「大小上限 + 去元数据」，不能因为读不出尺寸就把正常照片拒了。 */
const IMG_UNPARSED_OK = { 'image/heic': 1, 'image/heif': 1, 'image/tiff': 1 };

/** 去掉图片里的元数据（GPS / 设备 / 时间 / 注释）——隐私就藏在这里 */
function stripImageMeta(buf, mime) {
  try {
    if (mime === 'image/jpeg') {
      const out = [Buffer.from([0xff, 0xd8])];
      let i = 2;
      while (i < buf.length - 1) {
        if (buf[i] !== 0xff) { out.push(buf.slice(i)); break; }
        const mk = buf[i + 1];
        if (mk === 0xda) { out.push(buf.slice(i)); break; }                 // SOS 之后是图像数据，原样带走
        if (mk === 0x01 || (mk >= 0xd0 && mk <= 0xd9)) { i += 2; continue; }
        const len = buf.readUInt16BE(i + 2);
        if (len < 2 || i + 2 + len > buf.length) break;
        const drop = (mk >= 0xe1 && mk <= 0xef) || mk === 0xfe;             // APP1~APP15（EXIF/XMP/缩略图）、注释
        if (!drop) out.push(buf.slice(i, i + 2 + len));
        i += 2 + len;
      }
      return Buffer.concat(out);
    }
    if (mime === 'image/png') {
      if (!buf.slice(0, 8).equals(PNG_SIG)) return buf;
      const DROP = { tEXt: 1, zTXt: 1, iTXt: 1, eXIf: 1, tIME: 1, iCCP: 1 };
      const out = [PNG_SIG];
      let i = 8;
      while (i + 8 <= buf.length) {
        const len = buf.readUInt32BE(i);
        const type = buf.slice(i + 4, i + 8).toString('latin1');
        const total = 12 + len;
        if (i + total > buf.length) break;
        if (!DROP[type]) out.push(buf.slice(i, i + total));
        i += total;
        if (type === 'IEND') break;
      }
      return Buffer.concat(out);
    }
    if (mime === 'image/webp') {
      if (buf.length < 12 || buf.slice(0, 4).toString('latin1') !== 'RIFF') return buf;
      const out = [buf.slice(0, 12)];
      let i = 12;
      while (i + 8 <= buf.length) {
        const type = buf.slice(i, i + 4).toString('latin1');
        const len = buf.readUInt32LE(i + 4);
        const total = 8 + len + (len % 2);
        if (i + total > buf.length) break;
        if (type !== 'EXIF' && type !== 'XMP ') out.push(buf.slice(i, i + total));
        i += total;
      }
      return Buffer.concat(out);
    }
  } catch (err) { return buf; }
  return buf;
}

/** 体检：能不能解、会不会爆、元数据清干净。返回 { ok, buffer, error } */
function checkImage(buf, mime) {
  const size = imageSizeOf(buf, mime);
  if (!size || !(size.w > 0) || !(size.h > 0)) {
    if (IMG_UNPARSED_OK[mime]) return { ok: true, buffer: stripImageMeta(buf, mime) };
    return { ok: false, error: '这张图片读不出尺寸，可能不是正常图片（或者被改坏了）' };
  }
  if (size.w * size.h > IMG_MAX_PIXELS || size.w > IMG_MAX_SIDE || size.h > IMG_MAX_SIDE) {
    return { ok: false, error: '图片分辨率太大了（' + size.w + '×' + size.h + '），最多 4000 万像素、单边 12000' };
  }
  /* 大图自动缩小：这类图本身不是"炸弹"，但解码要吃几十上百 MB，手机容易卡/被杀进程 */
  const needShrink = size.w * size.h > IMG_SHRINK_PIXELS || size.w > IMG_SHRINK_SIDE || size.h > IMG_SHRINK_SIDE;
  /* 具体格式再验一遍：截断/全零/魔数不对的图，会让 App 里的解码器崩掉 */
  if (mime === 'image/png') {
    const idat = [];
    let i = 8, interlace = 0, bitDepth = 8, colorType = 6, seenIHDR = false;
    while (i + 8 <= buf.length) {
      const len = buf.readUInt32BE(i);
      const type = buf.slice(i + 4, i + 8).toString('latin1');
      if (i + 12 + len > buf.length) return { ok: false, error: '图片不完整（PNG 数据被截断了）' };
      if (type === 'IHDR') { seenIHDR = true; bitDepth = buf[i + 16]; colorType = buf[i + 17]; interlace = buf[i + 18]; }
      if (type === 'IDAT') idat.push(buf.slice(i + 8, i + 8 + len));
      i += 12 + len;
      if (type === 'IEND') break;
    }
    if (!seenIHDR || !idat.length) return { ok: false, error: '图片不完整（缺少 PNG 必要数据）' };
    const CH = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };
    const ch = CH[colorType] || 4;
    const bytesPerRow = Math.ceil(size.w * ch * bitDepth / 8);
    const expect = size.h * (bytesPerRow + 1);
    try {
      const raw = zlib.inflateSync(Buffer.concat(idat), { maxOutputLength: expect + 16 });
      if (interlace === 0 && raw.length !== expect) return { ok: false, error: '图片数据对不上（损坏或被裁剪过）' };
    } catch (err) {
      return { ok: false, error: '图片解不开（数据损坏）' };
    }
  } else if (mime === 'image/jpeg') {
    if (buf.length < 100 || buf[0] !== 0xff || buf[1] !== 0xd8) return { ok: false, error: '不是正常的 JPEG' };
    if (buf.indexOf(Buffer.from([0xff, 0xd9])) < 0) return { ok: false, error: 'JPEG 被截断了（没有结尾标记）' };
  } else if (mime === 'image/gif') {
    if (buf.slice(0, 4).toString('latin1') !== 'GIF8') return { ok: false, error: '不是正常的 GIF' };
    if (buf[buf.length - 1] !== 0x3b) return { ok: false, error: 'GIF 被截断了' };
  } else if (mime === 'image/webp') {
    if (buf.slice(0, 4).toString('latin1') !== 'RIFF' || buf.slice(8, 12).toString('latin1') !== 'WEBP') {
      return { ok: false, error: '不是正常的 WebP' };
    }
  }
  const cleaned = stripImageMeta(buf, mime);
  return { ok: true, buffer: cleaned, needShrink: needShrink, w: size.w, h: size.h };
}

/* 把超大图片缩到安全尺寸（写临时文件跑一次 ffmpeg，再读回来）。
   失败就返回 null，调用方原样保存 —— 不因为"缩图失败"把用户的上传搞砸。 */
function shrinkImageBuffer(buf, ext) {
  const FF = process.env.FFMPEG_PATH || 'C:/Users/Administrator/ffmpeg/bin/ffmpeg.exe';
  const rand = Date.now() + '_' + Math.random().toString(36).slice(2);
  const tmpIn = path.join(DATA_DIR, 'shrink_' + rand + ext);
  const tmpOut = path.join(DATA_DIR, 'shrink_' + rand + '_s' + ext);
  try {
    fs.writeFileSync(tmpIn, buf);
    const r = spawnSync(FF, ['-v', 'quiet', '-y', '-i', tmpIn,
      '-vf', "scale='min(" + IMG_SHRINK_SIDE + ",iw)':-2", '-q:v', '4', tmpOut], { encoding: 'utf8' });
    if (r.status !== 0 || !fs.existsSync(tmpOut)) return null;
    return fs.readFileSync(tmpOut);
  } catch (e) { return null; }
  finally {
    try { fs.unlinkSync(tmpIn); } catch (e) { }
    try { fs.unlinkSync(tmpOut); } catch (e) { }
  }
}

function saveUploadedFile(body) {
  /* base64 是二进制的 4/3：给到 2800 万字符，才容得下「20MB 视频」这个上限。
     以前写 1400 万，等于实际只能传 ~10MB，和下面那句 20MB 的限制对不上。 */
  /* 上限：单文件 80MB（base64 会涨成 ~107MB 字符）。
     以前写 5600 万字符 ≈ 只能发 42MB —— 大一点的视频/压缩包会被这里悄悄截断。 */
  let dataUrl = str(body.dataUrl, 112000000);
  /* 兼容「简写版」调用：有的后台页面发的是 {name, data(纯 base64)}，
     这里补成 dataUrl 再走同一套校验 —— 图片真实类型一律以文件头为准，
     所以就算这里按 PNG 包一层，JPEG 也能正确落成 .jpg。 */
  if (!dataUrl && body.data) {
    dataUrl = 'data:' + (str(body.mime, 60) || 'image/png') + ';base64,' + str(body.data, 56000000);
  }
  // mime 里可能带参数，比如 audio/webm;codecs=opus
  const m = /^data:([a-z0-9.+/-]+(?:;[a-z0-9-]+=[^;,]+)*);base64,([A-Za-z0-9+/=]+)$/i.exec(dataUrl);
  if (!m) return { error: 'dataUrl 格式不正确', status: 400 };
  const mime = m[1].split(';')[0].trim().toLowerCase();
  /* 安全：只收图片 / 音频 / 视频 / 文档 / 字体这些"数据"类型。
     text/html、image/svg+xml 这类能执行脚本的一律拒掉（不然就是存储型 XSS）。 */
  const SAFE_MIME = /^(image\/(png|jpeg|jpg|webp|gif|heic|heif|avif|bmp|tiff)|audio\/|video\/|application\/(pdf|zip|json|octet-stream|vnd\.ms-fontobject|x-font-ttf|font-woff)|text\/plain|font\/)/;
  if (!SAFE_MIME.test(mime)) {
    return { error: '不支持这种文件类型（只收图片、音视频、文档、字体）', status: 422 };
  }
  const isImage = mime.indexOf('image/') === 0;
  const extMap = {
    'image/png': '.png', 'image/jpeg': '.jpg', 'image/webp': '.webp', 'image/gif': '.gif', 'image/avif': '.avif',
    'image/heic': '.heic', 'image/heif': '.heif', 'image/bmp': '.bmp', 'image/tiff': '.tiff',
    'application/pdf': '.pdf', 'text/plain': '.txt', 'application/zip': '.zip',
    'application/json': '.json', 'video/mp4': '.mp4', 'audio/mpeg': '.mp3',
    'audio/webm': '.webm', 'audio/ogg': '.ogg', 'audio/mp4': '.m4a', 'audio/x-m4a': '.m4a',
    'audio/mpeg': '.mp3', 'audio/wav': '.wav', 'audio/x-wav': '.wav',
    'font/ttf': '.ttf', 'font/otf': '.otf', 'font/woff': '.woff', 'font/woff2': '.woff2',
    'application/font-woff': '.woff', 'application/x-font-ttf': '.ttf',
    'application/octet-stream': '.bin', 'application/vnd.ms-fontobject': '.eot'
  };
  const rawName = str(body.filename, 120);
  const nameExt = rawName && rawName.indexOf('.') !== -1 ? rawName.slice(rawName.lastIndexOf('.')) : '';
  /* 扩展名只认「类型 → 后缀」这一张白名单，文件名里的后缀一律不采信。
     否则拿不常见的类型（比如 image/heic）+ 文件名 xxx.php，就能在服务器上落地一个可执行后缀。 */
  const buffer0 = Buffer.from(m[2], 'base64');
  /* 有些客户端会把 JPEG 报成 image/png（名字叫 .png、内容却是 JPEG，iPhone 上很常见），
     以前按报来的类型去读文件头，就会报「这张图片读不出尺寸」。
     所以图片一律以**文件头**为准，不信客户端说的类型。 */
  const realMime = isImage ? (sniffImageMime(buffer0) || mime) : mime;
  let ext = extMap[realMime] || (isImage ? '.png' : '.bin');
  /* 唯一例外：浏览器读字体有时给 octet-stream，这时按文件名的字体后缀走（字体后缀本身在白名单里） */
  if (ext === '.bin' && /^\.(ttf|otf|woff2?|eot)$/i.test(nameExt)) ext = nameExt.toLowerCase();
  /* 音频同理：用户从别处下载的歌后缀五花八门（flac / ape / wma / opus …），
     浏览器给的 mime 常常是 octet-stream。后缀按**固定白名单**采信一次，
     随后 /api/manage/music 那边会用 ffmpeg 转成 mp3（见 transcodeAudioToMp3）。 */
  if (ext === '.bin' && /^\.(mp3|m4a|flac|wav|aac|ogg|oga|opus|ape|wma|aiff|aif|amr|mka)$/i.test(nameExt)) {
    ext = nameExt.toLowerCase();
  }
  ext = ext.toLowerCase();
  if (!/^\.(png|jpe?g|webp|gif|heic|heif|avif|bmp|tiff|pdf|txt|zip|json|mp4|mp3|m4a|webm|ogg|wav|ttf|otf|woff2?|eot|bin)$/.test(ext)) ext = isImage ? '.png' : '.bin';
  const buffer = buffer0;
  /* 非图片文件也看一眼「内容对不对得上类型」：exe/网页伪装成 pdf、zip 是常见手法 */
  if (!isImage) {
    const head = buffer.slice(0, 12);
    const str4 = head.toString('latin1');
    const CHECK = {
      'application/pdf': () => str4.indexOf('%PDF') === 0,
      'application/zip': () => head[0] === 0x50 && head[1] === 0x4b,
      'font/ttf': () => str4.indexOf('true') === 0 || str4.indexOf('OTTO') === 0 || head[0] === 0x00,
      'application/x-font-ttf': () => str4.indexOf('true') === 0 || str4.indexOf('OTTO') === 0 || head[0] === 0x00,
      'font/otf': () => str4.indexOf('OTTO') === 0,
      'font/woff': () => str4.indexOf('wOFF') === 0,
      'application/font-woff': () => str4.indexOf('wOFF') === 0,
      'font/woff2': () => str4.indexOf('wOF2') === 0,
      'audio/mpeg': () => str4.indexOf('ID3') === 0 || head[0] === 0xff,
      'audio/ogg': () => str4.indexOf('OggS') === 0,
      'audio/wav': () => str4.indexOf('RIFF') === 0,
      'audio/x-wav': () => str4.indexOf('RIFF') === 0,
      'video/mp4': () => str4.slice(4, 8) === 'ftyp',
      'audio/mp4': () => str4.slice(4, 8) === 'ftyp',
      'audio/x-m4a': () => str4.slice(4, 8) === 'ftyp',
      'video/webm': () => head[0] === 0x1a && head[1] === 0x45 && head[2] === 0xdf && head[3] === 0xa3,
      'audio/webm': () => head[0] === 0x1a && head[1] === 0x45 && head[2] === 0xdf && head[3] === 0xa3
    };
    const check = CHECK[realMime];
    if (check && !check()) return { error: '文件内容跟类型不符，拒绝保存', status: 422 };
  }
  const isFont = /\.(ttf|otf|woff2?|eot)$/i.test(ext);
  const isAudio = /^(audio|video)\//.test(mime);
  /* 视频放宽到 40MB（原样上传的画质最好），音频还是 20MB，其它 12MB */
  const isVideo = /^video\//.test(mime);
  const limit = isImage ? 8 * 1024 * 1024
    : (isFont ? 18 * 1024 * 1024 : (isAudio ? 20 * 1024 * 1024 : (isVideo ? 40 * 1024 * 1024 : 12 * 1024 * 1024)));
  if (buffer.length > limit) {
    return { error: (isImage ? '图片' : '文件') + '超过大小限制', status: 413 };
  }
  /* 图片统一体检 + 去元数据（GPS 之类的东西不能跟着图片走） */
  let payload = buffer;
  if (isImage) {
    const img = checkImage(buffer, realMime);
    if (!img.ok) return { error: img.error, status: 422 };
    payload = img.buffer;
    /* 300 万像素以上自动缩小：图片炸弹拦不掉的那类"大图"，也不会让手机解码爆内存 */
    if (img.needShrink) {
      const small = shrinkImageBuffer(img.buffer, ext);
      if (small && small.length) payload = small;
    }
  }
  ensureDirs();
  const name = uid(isImage ? 'img' : 'file') + ext;
  /* 落盘就是密文（见 sealUploadBuffer）：磁盘/备份被拿走也看不到图片内容 */
  fs.writeFileSync(path.join(UPLOAD_DIR, name), sealUploadBuffer(name, payload));
  return { url: '/uploads/' + name, name: rawName || name, bytes: payload.length, image: isImage };
}

/** 按文件头判断图片到底是什么格式（不信客户端报的 MIME —— iPhone 上
    「名字 .png、内容其实是 JPEG」非常常见，照报来的类型读头就会误判成坏图）。 */
function sniffImageMime(buf) {
  try {
    if (buf.length > 8 && buf.slice(0, 8).equals(PNG_SIG)) return 'image/png';
    if (buf.length > 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
    if (buf.length > 12 && buf.slice(0, 4).toString('latin1') === 'RIFF' && buf.slice(8, 12).toString('latin1') === 'WEBP') return 'image/webp';
    if (buf.length > 6 && buf.slice(0, 4).toString('latin1') === 'GIF8') return 'image/gif';
    if (buf.length > 2 && buf[0] === 0x42 && buf[1] === 0x4d) return 'image/bmp';
    if (buf.length > 12 && buf.slice(4, 8).toString('latin1') === 'ftyp') {
      const brand = buf.slice(8, 12).toString('latin1');
      if (/^hei|^he[vx]|mif1|msf1/.test(brand)) return 'image/heic';
      if (/^avif|avis/.test(brand)) return 'image/avif';
    }
  } catch (err) { /* 忽略 */ }
  return '';
}

async function handleAdmin(req, res, parts, query) {
  const method = req.method.toUpperCase();
  const sub = parts[1] || '';

  if (sub === 'login' && method === 'POST') {
    const body = await readBody(req);
    /* 安全：后台密码绝不允许走明文 http —— 同网段抓包就能拿到密码，拿到密码等于整个后台被拖走。
       本机（127.0.0.1）除外，方便本地脚本；其它来源一律要求 https。 */
    /* ⚠ 经过 TLS 前端回源的请求：socket.encrypted 是 false，但 X-Forwarded-Proto=https、
       而且 TCP 对端是本机 127.0.0.1 —— 客户端那一段本来就是加密的。
       以前只看 socket.encrypted，结果**所有从公网来的后台登录都被当成明文拒掉**
       （用户反馈的「后台进不去」：页面能打开，一登录就提示「必须走加密通道」）。 */
    const _rawPeerLogin = String((req.socket && req.socket.remoteAddress) || '').replace('::ffff:', '');
    const _viaTlsFrontLogin = /^(127\.0\.0\.1|::1)$/.test(_rawPeerLogin)
      && String(req.headers['x-forwarded-proto'] || '').toLowerCase() === 'https';
    if (!req.socket.encrypted && !_viaTlsFrontLogin
        && !/^(127\.0\.0\.1|::1)$/.test(peerIp(req))) {
      return fail(res, 403, httpsHint(req));
    }
    /* 账号：后台自己设的（data/admin.json 的 username）和默认的 admin 都收，
       免得浏览器自动填了 admin 就被判错、连着错五次锁 30 分钟 */
    const wantUser = String(adminAuth.username || 'admin').trim();
    const gotUser = String(body.username || '').trim();
    if (gotUser && gotUser !== wantUser && gotUser.toLowerCase() !== 'admin') {
      return fail(res, 401, '管理员账号或密码不正确');
    }
    if (!verifySecretRecord(adminAuth, String(body.password || '').trim())) {
      return fail(res, 401, '管理员密码不正确');
    }
    /* 把「我是谁」一起给页面，页面拿到就能直接进，不用再查一次会话 */
    /* 新后台（/manage.html）走的是 ops 会话，所以这里把两个 Cookie 都发：
       老 Cookie 给老页面，ops Cookie 给新后台，这样点开就直接能用全部页面。 */
    const superAdmin = (opsStore.admins || []).find((a) => a.role === 'super' && !a.disabled) || null;
    const cookies = [adminCookie(signAdminToken(), Math.floor(SESSION_TTL_MS / 1000))];
    let adminInfo = {
      id: 'root',
      username: String(adminAuth.username || 'admin'),
      name: '超级管理员',
      role: 'super',
      roleName: OPS_ROLE_NAMES.super,
      perms: OPS_ROLES.super || []
    };
    if (superAdmin) {
      cookies.push(OPS_COOKIE + '=' + encodeURIComponent(signOpsToken(superAdmin, clientInfo(req).ip))
        + '; Path=/; HttpOnly; SameSite=Lax; Max-Age=' + Math.floor(OPS_SESSION_TTL_MS / 1000));
      adminInfo = opsMe(superAdmin);
    }
    ok(res, { admin: adminInfo }, { 'Set-Cookie': cookies });
    return;
  }

  /* 免密登录（给后台登录页用）：/api/admin/quicklogin?pw=<管理员密码>
     密码对了就把登录 Cookie 发下去 —— 浏览器自动填错密码进不去时，用带 ?pw= 的链接点一下就能进。 */
  if (sub === 'quicklogin' && method === 'GET') {
    const pw = String(query.get('pw') || '').trim();
    if (!pw || !verifySecretRecord(adminAuth, pw)) {
      strikeIp(clientInfo(req).ip, '后台免密链接密码错');
      return fail(res, 401, '密码不对');
    }
    ok(res, { admin: true }, { 'Set-Cookie': adminCookie(signAdminToken(), Math.floor(SESSION_TTL_MS / 1000)) });
    return;
  }

  if (sub === 'logout' && method === 'POST') {
    ok(res, { loggedOut: true }, { 'Set-Cookie': adminCookie('', 0) });
    return;
  }

  if (sub === 'session' && method === 'GET') {
    const authed = isAdmin(req);
    ok(res, {
      authenticated: authed,
      /* 老式超管 Cookie 也要把「我是谁」带上：不带的话后台页面 start() 读不到名字会报错，
         表现就是「已经登录了却还停在登录页」。 */
      admin: authed ? {
        id: 'root',
        username: String(adminAuth.username || 'admin'),
        name: '超级管理员',
        role: 'super',
        roleName: OPS_ROLE_NAMES.super,
        perms: OPS_ROLES.super || []
      } : null,
      defaultPasswordInUse: verifySecretRecord(adminAuth, DEFAULT_ADMIN_PASSWORD)
    });
    return;
  }

  if (!isAdmin(req)) return fail(res, 401, '请先登录管理后台');

  /* AI 助手 / 管家的配置：密钥、模型、人设、自动回复开关 */
  if (sub === 'ai' && method === 'GET') {
    const cfg = readAiCfg();
    ok(res, {
      ai: {
        enabled: !!cfg.enabled,
        autoReply: !!cfg.autoReply,
        baseUrl: cfg.baseUrl || AI_DEFAULT.baseUrl,
        model: cfg.model || AI_DEFAULT.model,
        systemPrompt: cfg.systemPrompt || '',
        housekeeperPrompt: cfg.housekeeperPrompt || AI_DEFAULT.housekeeperPrompt || '',
        hasKey: !!cfg.apiKey,
        keyTail: cfg.apiKey ? ('****' + String(cfg.apiKey).slice(-4)) : '',
        bots: db.users.filter((u) => u.bot).map((u) => ({ id: u.id, username: u.username, nickname: u.nickname }))
      }
    });
    return;
  }
  if (sub === 'ai' && method === 'POST') {
    const body = await readBody(req);
    const patch = {};
    if (body.enabled !== undefined) patch.enabled = !!body.enabled;
    if (body.autoReply !== undefined) patch.autoReply = !!body.autoReply;
    if (body.baseUrl !== undefined) patch.baseUrl = str(body.baseUrl, 200) || AI_DEFAULT.baseUrl;
    if (body.model !== undefined) patch.model = str(body.model, 60) || AI_DEFAULT.model;
    if (body.systemPrompt !== undefined) patch.systemPrompt = str(body.systemPrompt, 2000);
    if (body.housekeeperPrompt !== undefined) patch.housekeeperPrompt = str(body.housekeeperPrompt, 2000);
    if (body.apiKey !== undefined && String(body.apiKey).trim()) patch.apiKey = String(body.apiKey).trim().slice(0, 200);
    const next = saveAiCfg(patch);
    ensureBots();
    ok(res, { saved: true, hasKey: !!next.apiKey });
    return;
  }

  if (sub === 'stats' && method === 'GET') { ok(res, adminStats()); return; }

  /* ---------- 新版后台：菜单 / 总览 / 通用列表 / 通用操作 ---------- */
  if (sub === 'nav' && method === 'GET') { ok(res, { nav: ADMIN_NAV }); return; }
  if (sub === 'dash' && method === 'GET') { ok(res, dashboardStats()); return; }
  if (sub === 'rows' && method === 'GET') {
    const name = str(query.get('name'), 40);
    if (!name) return fail(res, 400, '缺少 name');
    ok(res, datasetRows(name, query));
    return;
  }
  if (sub === 'act' && method === 'POST') {
    const body = await readBody(req);
    const r = adminAct(body);
    if (r && r.error) return fail(res, r.status || 400, r.error);
    ok(res, r || {});
    return;
  }

  if (sub === 'branding' && method === 'GET') {
    ok(res, { branding: db.branding });
    return;
  }

  /* ---------- ＋ 面板（控制台可改名称 / 图标 / 动作 / 开关 / 顺序） ---------- */
  if (sub === 'plus-panel' && method === 'GET') {
    ok(res, {
      items: db.plusPanel, icons: PLUS_ICONS, actions: PLUS_ACTIONS, defaults: DEFAULT_PLUS_ITEMS,
      /* 输入框上面那排快捷按钮 + 「＋」按钮的外观 */
      quick: db.quickBar, quickActions: QUICK_ACTIONS, quickDefaults: DEFAULT_QUICK_ITEMS,
      plus: db.plusButton
    });
    return;
  }

  if (sub === 'plus-panel' && method === 'PUT') {
    const body = await readBody(req);
    /* items / quick / plus 三个都能单独改（老后台只传 items 也照样能用） */
    if (body.items !== undefined) {
      if (!Array.isArray(body.items)) return fail(res, 400, 'items 必须是数组');
      db.plusPanel = normalizePlusItems(body.items);
    }
    if (body.quick !== undefined) {
      if (!Array.isArray(body.quick)) return fail(res, 400, 'quick 必须是数组');
      db.quickBar = normalizeQuickItems(body.quick);
    }
    if (body.plus !== undefined) db.plusButton = normalizePlusButton(body.plus);
    savePlusPanel();
    // 在线用户实时更新，不用刷新
    connections.forEach(function (set, userId) {
      sendTo(userId, { type: 'pluspanel', items: db.plusPanel, quick: db.quickBar, plus: db.plusButton });
    });
    ok(res, { items: db.plusPanel, quick: db.quickBar, plus: db.plusButton });
    return;
  }

  /* ---------- 礼物管理：加礼物 / 改名 / 换图标 / 定价 / 分类 / 上下架 ---------- */
  if (sub === 'gifts' && method === 'GET') {
    const cats = [];
    db.gifts.concat(DEFAULT_GIFTS).forEach(function (g) {
      if (g.category && cats.indexOf(g.category) < 0) cats.push(g.category);
    });
    ok(res, { gifts: db.gifts, icons: GIFT_ICON_PRESETS, categories: cats, defaults: DEFAULT_GIFTS });
    return;
  }

  if (sub === 'gifts' && method === 'PUT') {
    const body = await readBody(req);
    if (!Array.isArray(body.gifts)) return fail(res, 400, 'gifts 必须是数组');
    db.gifts = normalizeGifts(body.gifts);
    saveGifts();
    connections.forEach(function (set, userId) {
      sendTo(userId, { type: 'gifts', gifts: db.gifts });
    });
    ok(res, { gifts: db.gifts });
    return;
  }

  /* ---------- 状态管理：分类 + 每个分类里的状态 ---------- */
  if (sub === 'statuses' && parts.length === 2 && method === 'GET') {
    ok(res, { categories: db.statuses, defaults: STATUS_DEFAULT });
    return;
  }

  if (sub === 'statuses' && method === 'PUT') {
    const body = await readBody(req);
    if (!Array.isArray(body.categories)) return fail(res, 400, 'categories 必须是数组');
    db.statuses = normalizeStatus(body.categories);
    saveStatuses();
    connections.forEach(function (set, userId) {
      sendTo(userId, { type: 'statuses', categories: db.statuses.filter((c) => c.enabled) });
    });
    ok(res, { categories: db.statuses });
    return;
  }

  /* ---------- 表情包管理：本地表情包 + 第三方图源 ---------- */
  // 后台「测试」按钮：拿当前配置去第三方搜一下，把结果和错误原样返回
  if (sub === 'stickers' && parts[2] === 'test' && method === 'GET') {
    const url = thirdPartyUrl(db.stickers.thirdParty, str(query.get('q'), 30) || '开心');
    if (!url) return ok(res, { items: [], error: '还没选第三方服务或没填 key / 接口地址' });
    try {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), 8000);
      const r = await fetch(url, { signal: ctl.signal, headers: { Accept: 'application/json' } });
      clearTimeout(timer);
      const data = await r.json().catch(() => null);
      ok(res, { url: url.replace(/key=[^&]+/i, 'key=****'), status: r.status, items: parseThirdParty(db.stickers.thirdParty.provider, data).slice(0, 8) });
    } catch (err) {
      ok(res, { error: '请求失败：' + (err && err.message ? err.message : '未知错误') });
    }
    return;
  }

  if (sub === 'stickers' && parts.length === 2 && method === 'GET') {
    ok(res, {
      packs: db.stickers.packs,
      thirdParty: db.stickers.thirdParty,
      providers: STICKER_PROVIDERS,
      defaults: STICKER_PACKS_DEFAULT
    });
    return;
  }

  if (sub === 'stickers' && method === 'PUT') {
    const body = await readBody(req);
    const next = normalizeStickers({
      packs: Array.isArray(body.packs) ? body.packs : db.stickers.packs,
      thirdParty: body.thirdParty && typeof body.thirdParty === 'object'
        ? Object.assign({}, db.stickers.thirdParty, body.thirdParty)
        : db.stickers.thirdParty
    });
    db.stickers = next;
    saveStickers();
    connections.forEach(function (set, userId) {
      sendTo(userId, { type: 'stickers', packs: db.stickers.packs.filter((p) => p.enabled) });
    });
    ok(res, { packs: db.stickers.packs, thirdParty: db.stickers.thirdParty });
    return;
  }

  if (sub === 'upload' && method === 'POST') {
    const body = await readBody(req);
    const saved = saveUploadedFile(body);
    if (saved.error) return fail(res, saved.status, saved.error);
    ok(res, saved);
    return;
  }

  if (sub === 'branding' && method === 'PUT') {
    const body = await readBody(req);
    const next = Object.assign({}, db.branding);
    if (body.appName !== undefined) next.appName = str(body.appName, 30) || DEFAULT_BRANDING.appName;
    if (body.logo !== undefined) next.logo = str(body.logo, 300000);
    if (body.chatBackground !== undefined) next.chatBackground = str(body.chatBackground, 300000);
    /* 启动页图片（后台可换，不用重新出包） */
    if (body.splash !== undefined) next.splash = str(body.splash, 300000);
    if (body.fontFamily !== undefined) next.fontFamily = str(body.fontFamily, 400);
    if (body.fontName !== undefined) next.fontName = str(body.fontName, 120);
    if (body.fontUrl !== undefined) next.fontUrl = str(body.fontUrl, 500000);
    if (body.fontScale !== undefined) {
      const fs2 = Number(body.fontScale);
      next.fontScale = (isFinite(fs2) && fs2 >= 0.8 && fs2 <= 1.4) ? Math.round(fs2 * 100) / 100 : 1;
    }
    if (body.accentColor !== undefined) next.accentColor = hexColor(body.accentColor);
    if (body.textColor !== undefined) next.textColor = hexColor(body.textColor);
    if (body.iceServers !== undefined) next.iceServers = str(body.iceServers, 4000);
    if (body.icons && typeof body.icons === 'object') {
      next.icons = Object.assign({}, db.branding.icons);
      Object.keys(DEFAULT_BRANDING.icons).forEach(function (key) {
        if (body.icons[key] !== undefined) next.icons[key] = str(body.icons[key], 300000);
      });
    }
    next.updatedAt = now();
    db.branding = next;
    saveBranding();
    // 所有在线用户实时换图标，不用刷新
    connections.forEach(function (set, userId) {
      sendTo(userId, { type: 'branding', branding: db.branding });
    });
    ok(res, { branding: db.branding });
    return;
  }

  if (sub === 'system' && method === 'GET') {
    ok(res, {
      node: process.version,
      platform: process.platform,
      port: PORT,
      host: HOST,
      dataDir: DATA_DIR,
      uptimeSeconds: Math.round(process.uptime()),
      memoryMB: Math.round(process.memoryUsage().rss / 1024 / 1024),
      startedAt: new Date(Date.now() - process.uptime() * 1000).toISOString()
    });
    return;
  }

  if (sub === 'users' && method === 'GET') {
    const q = str(query.get('q'), 30).toLowerCase();
    const page = Math.max(1, Number(query.get('page')) || 1);
    const pageSize = Math.min(100, Number(query.get('pageSize')) || 30);
    let list = db.users.slice().sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    if (q) list = list.filter((u) => u.username.toLowerCase().includes(q) || u.nickname.toLowerCase().includes(q));
    const online = onlineUserIds();
    const total = list.length;
    ok(res, {
      users: list.slice((page - 1) * pageSize, page * pageSize).map((u) => ({
        id: u.id,
        username: u.username,
        nickname: u.nickname,
        realName: u.realName || '',                  // 真名（只有后台能看到）
        realNameMask: realNameOf(u),                 // 手机端转账页显示的这个
        realNameHidden: u.realNameHidden !== false,
        balance: Number(u.balance) || 0,             // 零钱余额
        transferLimit: u.transferLimit === undefined ? 20000 : Number(u.transferLimit) || 0,   // 单笔转账限额（0=不限）
        avatar: u.avatar || '',
        bio: u.bio || '',
        gender: u.gender || '',
        banned: !!u.banned,
        createdAt: u.createdAt,
        friendCount: friendIds(u.id).length,
        momentCount: db.moments.filter((m) => m.authorId === u.id).length,
        chatCount: chatsOf(u.id).length,
        online: online.includes(u.id)
      })),
      total, page, pageSize
    });
    return;
  }

  if (sub === 'users' && method === 'PATCH') {
    const target = findUser(parts[2]);
    if (!target) return fail(res, 404, '用户不存在');
    const body = await readBody(req);
    if (body.banned !== undefined) {
      target.banned = !!body.banned;
      if (target.banned) closeUserConnections(target.id);
    }
    if (body.nickname !== undefined) target.nickname = str(body.nickname, 24) || target.nickname;
    if (body.gender !== undefined) target.gender = normalizeGender(body.gender);
    if (body.realName !== undefined) target.realName = str(body.realName, 24);          // 允许清空
    if (body.realNameHidden !== undefined) target.realNameHidden = !!body.realNameHidden;
    if (body.balance !== undefined) {
      /* 走统一入口：后台直接改余额同样要记总账（以前这里是裸赋值，不进账）。
         管理员改账允许改成 0 或调减，所以放行负数检查。 */
      const want = Number(body.balance);
      const nextBal = isFinite(want) && want > 0 ? moneyRound(want) : 0;
      const curBal = moneyRound(target.balance) || 0;
      applyMoney(target, nextBal - curBal, {
        reason: '后台直接改余额',
        ref: (admin && admin.username) || '',
        allowNegative: true
      });
      sendTo(target.id, { type: 'balance', balance: target.balance });      // 在线的话余额立刻刷新
    }
    if (body.transferLimit !== undefined) {
      const l = Number(body.transferLimit);
      target.transferLimit = isFinite(l) && l > 0 ? Math.round(l * 100) / 100 : 0;   // 0 = 不限
    }
    if (body.password) {
      if (String(body.password).length < 6) return fail(res, 422, '新密码至少 6 位');
      const salt = crypto.randomBytes(16).toString('hex');
      target.salt = salt;
      target.passwordHash = hashPassword(String(body.password), salt);
    }
    saveUsers();
    // 实名变了：让这个人的好友和本人马上能看到新的显示名
    friendIds(target.id).forEach((fid) => sendTo(fid, { type: 'profile', user: publicUser(target) }));
    sendTo(target.id, { type: 'profile', user: publicUser(target) });
    ok(res, { user: { id: target.id, username: target.username, nickname: target.nickname, gender: target.gender || '', banned: !!target.banned } });
    return;
  }

  /* 余额充值：后台给某个用户充值（amount 是加多少，不是设多少） */
  if (sub === 'users' && parts[2] && parts[3] === 'recharge' && method === 'POST') {
    const target = findUser(parts[2]);
    if (!target) return fail(res, 404, '用户不存在');
    const body = await readBody(req);
    const amount = Math.round((Number(body.amount) || 0) * 100) / 100;
    if (!(amount > 0)) return fail(res, 422, '充值金额要大于 0');
    if (amount > 1000000) return fail(res, 422, '单次充值不能超过 1000000');
    const before = Number(target.balance) || 0;
    applyMoney(target, amount, { reason: '后台充值', ref: (admin && admin.username) || '' });
    saveUsers();
    sendTo(target.id, { type: 'balance', balance: target.balance });      // 在线的话余额立刻刷新
    ok(res, { id: target.id, username: target.username, nickname: target.nickname, recharged: amount, balanceBefore: before, balance: target.balance });
    return;
  }

  if (sub === 'users' && method === 'DELETE') {
    const target = findUser(parts[2]);
    if (!target) return fail(res, 404, '用户不存在');
    closeUserConnections(target.id);
    db.users = db.users.filter((u) => u.id !== target.id);
    db.friendships = db.friendships.filter((f) => f.fromId !== target.id && f.toId !== target.id);
    db.moments = db.moments.filter((m) => m.authorId !== target.id);
    db.chats = db.chats
      .filter((c) => !(c.type === 'direct' && c.memberIds.includes(target.id)))
      .map((c) => Object.assign(c, { memberIds: c.memberIds.filter((id) => id !== target.id) }))
      .filter((c) => c.memberIds.length >= 2);
    delete db.reads[target.id];
    delete db.momentViews[target.id];
    saveUsers(); saveFriendships(); saveMoments(); saveChats(); saveReads(); saveMomentViews();
    ok(res, { deleted: true, username: target.username });
    return;
  }

  if (sub === 'moments' && method === 'GET') {
    const page = Math.max(1, Number(query.get('page')) || 1);
    const pageSize = Math.min(50, Number(query.get('pageSize')) || 20);
    const list = db.moments.slice().sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    ok(res, {
      moments: list.slice((page - 1) * pageSize, page * pageSize).map((m) => ({
        id: m.id,
        author: publicUser(findUser(m.authorId)),
        content: m.content,
        images: m.images || [],
        likes: (m.likes || []).length,
        comments: (m.comments || []).length,
        createdAt: m.createdAt
      })),
      total: list.length, page, pageSize
    });
    return;
  }

  if (sub === 'moments' && method === 'DELETE') {
    const idx = db.moments.findIndex((m) => m.id === parts[2]);
    if (idx === -1) return fail(res, 404, '动态不存在');
    const [removed] = db.moments.splice(idx, 1);
    saveMoments();
    broadcastMoment(removed.authorId, {
      type: 'moment', action: 'delete', momentId: removed.id, authorId: removed.authorId
    });
    ok(res, { deleted: true });
    return;
  }

  if (sub === 'chats' && method === 'GET') {
    const page = Math.max(1, Number(query.get('page')) || 1);
    const pageSize = Math.min(50, Number(query.get('pageSize')) || 20);
    const list = db.chats.slice().sort((a, b) => {
      const la = loadMessages(a.id);
      const lb = loadMessages(b.id);
      const ta = la.length ? la[la.length - 1].createdAt : a.createdAt;
      const tb = lb.length ? lb[lb.length - 1].createdAt : b.createdAt;
      return String(tb).localeCompare(String(ta));
    });
    ok(res, {
      chats: list.slice((page - 1) * pageSize, page * pageSize).map((c) => {
        const messages = loadMessages(c.id);
        const last = messages.length ? messages[messages.length - 1] : null;
        const pv = lastPreviewMessage(messages);
        return {
          id: c.id,
          type: c.type,
          name: c.type === 'group' ? c.name : '',
          members: c.memberIds.map((id) => publicUser(findUser(id))).filter(Boolean),
          messageCount: messages.length,
          lastMessage: last ? {
            senderId: (pv || last).senderId,
            preview: pv ? previewTextOf(pv) : '',
            createdAt: last.createdAt
          } : null,
          createdAt: c.createdAt
        };
      }),
      total: list.length, page, pageSize
    });
    return;
  }

  if (sub === 'messages' && method === 'GET') {
    const chat = db.chats.find((c) => c.id === str(query.get('chatId'), 40));
    if (!chat) return fail(res, 404, '会话不存在');
    const limit = Math.min(200, Number(query.get('limit')) || 50);
    ok(res, {
      chat: {
        id: chat.id, type: chat.type, name: chat.name,
        members: chat.memberIds.map((id) => publicUser(findUser(id))).filter(Boolean)
      },
      messages: loadMessages(chat.id).slice(-limit).map((m) => ({
        id: m.id,
        seq: m.seq,
        senderId: m.senderId,
        senderName: (findUser(m.senderId) || {}).nickname || (m.senderId === 'system' ? '系统公告' : '已注销用户'),
        kind: m.kind,
        content: m.content,
        /* 通话记录带上通话本身的信息（音频/视频、接通没接通、时长），
           客户端拿它画电话/摄像机小图标 */
        call: m.call || null,
        recalled: !!m.recalled,
        createdAt: m.createdAt
      }))
    });
    return;
  }

  if (sub === 'broadcast' && method === 'POST') {
    const body = await readBody(req);
    const content = str(body.content, 300);
    if (!content) return fail(res, 422, '公告内容不能为空');
    let chats = 0;
    db.chats.forEach((chat) => {
      chat.seq = (chat.seq || 0) + 1;
      const message = {
        id: uid('m'), chatId: chat.id, seq: chat.seq, senderId: 'system',
        kind: 'system', content, createdAt: now(), recalled: false
      };
      appendMessage(chat.id, message);
      chat.memberIds.forEach((id) => {
        sendTo(id, { type: 'message', message, chat: chatSummary(chat, id), clientId: null });
      });
      chats += 1;
    });
    saveChats();
    const record = { id: uid('an'), content, createdAt: now(), chats };
    db.announcements.unshift(record);
    db.announcements = db.announcements.slice(0, 50);
    saveAnnouncements();
    ok(res, { announcement: record });
    return;
  }

  if (sub === 'announcements' && method === 'GET') {
    ok(res, { announcements: db.announcements.slice(0, 50) });
    return;
  }

  fail(res, 404, '管理接口不存在');
}

/* ============================================================ 附近的人
   微信的「发现 → 附近」：进过这个页的人会把位置报到服务器（data/nearby.json），
   半小时内的算「附近」；别人进来就能看到按距离排的名单，可以打招呼。
   隐私：只存最近一次的位置和时间，超时就自动清掉；本人可以隐身（visible=false）。 */
const NEARBY_TTL_MS = 30 * 60 * 1000;      // 半小时内报过位置才算「附近」
const NEARBY_MAX_KM = 5;                   // 只显示 5 公里以内的（用户要求；微信也是这个量级）
let nearbyCache = null;
function nearbyFile() { return path.join(DATA_DIR, 'nearby.json'); }
function loadNearby() {
  if (nearbyCache) return nearbyCache;
  const d = readJson(nearbyFile(), { users: {} });
  nearbyCache = (d && typeof d.users === 'object' && d.users) ? d.users : {};
  return nearbyCache;
}
function saveNearby() {
  if (!nearbyCache) return;
  writeJson(nearbyFile(), { users: nearbyCache, savedAt: now() });
}
/** 顺手把过期的位置删掉，别让文件越堆越大 */
function pruneNearby() {
  const map = loadNearby();
  const cut = Date.now() - NEARBY_TTL_MS;
  let changed = false;
  Object.keys(map).forEach((id) => {
    if (!map[id] || !(map[id].at > cut) || !findUser(id)) { delete map[id]; changed = true; }
  });
  return changed;
}
/** 两点之间的距离（公里）：球面公式，够用 */
function nearbyKm(a, b) {
  const R = 6371;
  const rad = (x) => (x * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2
    + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

/* ============================================================ 摇一摇
   微信的逻辑：你摇的那几秒里，另一个也在摇的人会被摇到。
   所以服务器只记「最近 30 秒内谁摇了」，两边一撞就配对；
   5 分钟内不再摇到同一个人（不然一直摇到同一个太假）。 */
const SHAKE_TTL_MS = 30 * 1000;
const SHAKE_AGAIN_MS = 5 * 60 * 1000;
let shakeCache = null;
function shakeFile() { return path.join(DATA_DIR, 'shake.json'); }
function loadShakes() {
  if (shakeCache) return shakeCache;
  const d = readJson(shakeFile(), { users: {} });
  shakeCache = (d && typeof d.users === 'object' && d.users) ? d.users : {};
  return shakeCache;
}
function saveShakes() {
  if (!shakeCache) return;
  writeJson(shakeFile(), { users: shakeCache, savedAt: now() });
}

/* ============================================================ 直播专场（轻量）
   房间名单在 data/live.json（后台直接改文件就行）；
   这里只在内存里记「谁在看这个房间」和「多少赞」，弹幕/点赞走长连接实时广播。 */
const liveViewers = new Map();     // roomId -> Set(userId)
const liveLikes = new Map();       // roomId -> 点赞数
const liveHosts = new Map();       // roomId -> 正在推流的那个人
/* 视频号的后台可调项：样式（数字/颜色）+ 开关。前台发布不受这些影响，除非开关关掉。 */
const FEED_STYLE_DEFAULT = {
  avatar: 46,          // 右侧头像大小
  nameSize: 16,        // 作者名字号
  descSize: 14,        // 文案字号
  musicSize: 12.5,     // 音乐字号
  railIcon: 27,        // 右侧动作图标大小
  railGap: 20,         // 动作栏间距
  padBottom: 28,       // 底部留白
  corner: 0            // 0 = 全屏；>0 = 卡片圆角（留个口子）
};
const FEED_FLAGS_DEFAULT = {
  allowPublish: true,  // 前台能不能自己发视频
  allowTrim: true,     // 发布时能不能剪水印
  showRail: true,      // 显示右侧动作栏（赞/评论/分享）
  autoPlay: true       // 进入就自动播当前这条
};
function normalizeFeedStyle(s) {
  const out = Object.assign({}, FEED_STYLE_DEFAULT);
  Object.keys(FEED_STYLE_DEFAULT).forEach((k) => {
    const v = Number(s[k]);
    if (isFinite(v) && v >= 0 && v <= 400) out[k] = v;
  });
  return out;
}
function normalizeFeedFlags(s) {
  const out = Object.assign({}, FEED_FLAGS_DEFAULT);
  Object.keys(FEED_FLAGS_DEFAULT).forEach((k) => {
    if (s[k] !== undefined) out[k] = !!s[k];
  });
  return out;
}
function liveBroadcast(roomId, payload) {
  const set = liveViewers.get(roomId);
  if (!set || !set.size) return;
  set.forEach((uid) => sendTo(uid, payload));
}
function pruneShakes() {
  const map = loadShakes();
  const cut = Date.now() - SHAKE_TTL_MS;
  Object.keys(map).forEach((id) => {
    const r = map[id];
    if (!r || !(r.at > cut) || !findUser(id)) delete map[id];
  });
  return map;
}

async function handleApi(req, res, pathname, query) {
  const method = req.method.toUpperCase();
  const parts = pathname.split('/').filter(Boolean).slice(1);
  /* ⚠ 这一句必须在**所有**路由之前：以前它被放在函数中间，
     JS 的 TDZ 会让它前面那些接口（音乐点赞、状态点赞、注册…）一调用就报
     "Cannot access 'user' before initialization"。别往下挪。 */
  const user = currentUser(req);

  if (parts[0] === 'admin') {
    await handleAdmin(req, res, parts, query);
    return;
  }

  /* 独立的管理员后台（/manage.html）：多账号 + 角色 + 审计日志 + 风控 */
  /* ============================================================ 小店 + 卡包
     2026-10-11 照微信的逻辑加的两块：
       · 小店：商品列表 → 下单（走零钱扣款，和 AI 那边"点第 1 个"同一个道理）→ 我的订单
       · 卡包：我的卡券（优惠券 / 会员卡 / 礼品卡 / 票），带核销码；管理侧能发卡、核销
     数据落 data/shop.json（商品）+ data/cards.json（卡券）+ 复用 data/orders.json（订单）。
     管理侧（上架/下架/改价/发卡）走 /api/ops/*，只有 ops 账号能用。
     ============================================================ */
  function readShopCfg() {
    const def = (function () {
      try { const s = loadShop(); return { items: (s.goods || []).map((g, i) => ({ id: 'g' + (i + 1), name: g.name, price: g.price, img: g.img || '', kind: 'physical', desc: '', stock: 999, on: true, sort: i })) }; }
      catch (e) { return { items: [] }; }
    })();
    const f = path.join(DATA_DIR, 'shop.json');
    const cfg = readJson(f, null);
    if (!cfg || !Array.isArray(cfg.items)) { writeJson(f, def); return def; }
    return cfg;
  }
  function saveShopCfg(cfg) { writeJson(path.join(DATA_DIR, 'shop.json'), cfg); }
  function readCards() { const f = path.join(DATA_DIR, 'cards.json'); const c = readJson(f, { cards: [] }); if (!Array.isArray(c.cards)) c.cards = []; return c; }
  function saveCards(c) { writeJson(path.join(DATA_DIR, 'cards.json'), c); }
  function isOpsUser(u) { return !!(u && (u.ops === true || u.admin === true)); }

  /* ============================================================ 小星（顶栏那颗眼睛）的三档开关
     2026-10-12 用户要求：**每个用户自己设**，而且"开启小星"是付费的（¥40 一次性）。
       · off    ：顶栏不画（免费，最安全）
       · static ：画但不动（免费；两段 repeatForever 动画不跑）
       · on     ：会动的眼睛（¥40 一次性买断，走零钱；余额不足告诉他还差多少）
     状态存在用户对象上（跟着账号走，换设备也在）；管理侧能免费给某个用户开。
     端点：GET/POST /api/me/eyes、POST /api/ops/eyes
     ============================================================ */
  const EYES_PRICE = 40;
  if (parts[0] === 'me' && parts[1] === 'eyes' && method === 'GET') {
    ok(res, { eyes: user.eyes || 'on', paid: user.eyesPaidAt ? true : false,
              price: EYES_PRICE, balance: Number(user.balance) || 0 });
    return;
  }
  if (parts[0] === 'me' && parts[1] === 'eyes' && method === 'POST') {
    const b = await readBody(req);
    const want = String(b.eyes || '').trim();
    if (!['on', 'static', 'off'].includes(want)) return fail(res, 400, '档位不对');
    if (want === 'on' && !user.eyesPaidAt) {
      const bal = Number(user.balance) || 0;
      if (bal < EYES_PRICE) return fail(res, 400, '零钱不够（还差 ' + money(EYES_PRICE - bal) + '），去「我 → 服务 → 充值余额」');
      user.balance = Math.round((bal - EYES_PRICE) * 100) / 100;
      user.eyesPaidAt = now();
      sendTo(user.id, { type: 'balance', balance: user.balance });
    }
    user.eyes = want;
    saveUsers();
    ok(res, { eyes: user.eyes, paid: user.eyesPaidAt ? true : false, balance: Number(user.balance) || 0 });
    return;
  }
  if (parts[0] === 'ops' && parts[1] === 'eyes' && method === 'POST') {
    if (!isOpsUser(user)) return fail(res, 403, '没有权限');
    const b = await readBody(req);
    const target = findUser(String(b.userId || '')) || user;
    const want = String(b.eyes || 'on').trim();
    if (['on', 'static', 'off'].includes(want)) {
      target.eyes = want;
      if (want === 'on' && !target.eyesPaidAt) target.eyesPaidAt = now();   // 管理侧免费开
      saveUsers();
    }
    ok(res, { userId: target.id, eyes: target.eyes || 'on', paid: target.eyesPaidAt ? true : false });
    return;
  }

  /* ============================================================ 拼多多商城（原生）CHRIS_MALL_ADMIN_V1
     2026-10-12 用户要求「拼多多商城后台给管理（可以上架的 / 换轮播图的）」：
     商城数据从 App 内置搬到这里，落 data/mall.json = { products: [...], banners: [...] }
       · GET  /api/mall       → { products, banners }（App 的商城首页/详情读它）
       · POST /api/ops/mall   → 管理侧（上架/下架/改价/删除/新增商品 + 换轮播图），只有 ops 能调
     商品字段：id / em（emoji 图标）/ img（图片地址，可空）/ title / price（拼单价）/
              orig（单买价）/ sold / grp（几人团）/ tags / shop / cate / on（是否上架）
     没文件就按 App 里那 16 个内置商品 + 3 张渐变轮播图种子写一份。
     ============================================================ */
  function mallSeed() {
    const P = [
      ['p01','🎧','【百亿补贴】无线蓝牙耳机 主动降噪 入耳式 超长续航 苹果安卓通用',39.9,199,'10万+',2,['百亿补贴','官方直营'],'数码优选旗舰店','数码'],
      ['p02','👟','轻便透气跑步鞋 男款夏季网面运动鞋 软底减震',59.9,159,'3.2万',2,['限时秒杀','退货包运费'],'潮鞋工厂店','服饰'],
      ['p03','🍊','现摘沃柑 5斤装 手剥甜橙 新鲜当季水果 产地直发',16.8,39.9,'8.6万',2,['产地直发','坏果包赔'],'果农直供店','生鲜'],
      ['p04','🧴','氨基酸洗面奶 深层清洁温和不紧绷 敏感肌可用 200ml',19.9,69,'5.1万',3,['正品保障'],'肌研美妆专营','美妆'],
      ['p05','☕','保温杯 316不锈钢 大容量便携车载水杯 24小时保温',29.9,99,'2.7万',2,['限时秒杀'],'日用家居优选','家居'],
      ['p06','🍜','螺蛳粉 广西正宗柳州风味 5包装 加臭加辣速食',24.9,49.9,'12万',2,['百亿补贴','爆款'],'美味零食铺','食品'],
      ['p07','📱','120W超级快充充电宝 20000毫安 大容量 自带四线',69,199,'4.4万',2,['官方补贴'],'数码优选旗舰店','数码'],
      ['p08','🧸','儿童毛绒玩具公仔 安抚陪睡娃娃 生日礼物正版授权',22.8,79,'1.9万',3,['母婴优选'],'萌趣玩具城','母婴'],
      ['p09','👕','纯棉短袖T恤 男款夏季宽松百搭 三件装 不易变形',39.9,129,'6.8万',2,['退货包运费'],'基础款服饰店','服饰'],
      ['p10','🥛','纯牛奶 250ml×12盒 全脂营养早餐奶 整箱实惠装',33.9,69,'9.3万',2,['百亿补贴','日期新鲜'],'乳品官方旗舰','食品'],
      ['p11','🪥','电动牙刷 声波震动 智能定时 情侣款 含4个刷头',45.9,169,'2.2万',2,['限时秒杀'],'口腔护理专营','美妆'],
      ['p12','🍚','东北五常大米 10斤装 当季新米 香糯软弹 真空包装',34.9,79,'7.5万',2,['产地直发'],'粮油旗舰店','食品'],
      ['p13','⌚','智能运动手环 心率血氧监测 防水计步 长续航 通用腕带',79,299,'1.6万',3,['官方补贴'],'数码优选旗舰店','数码'],
      ['p14','🧺','衣物收纳箱 大容量可折叠 防潮防尘 衣柜整理三件套',26.9,89,'3.7万',2,['9.9元包邮'],'日用家居优选','家居'],
      ['p15','🍰','千层蛋糕 动物奶油 现做现发 网红下午茶甜品',29.9,88,'2.5万',2,['顺丰冷链'],'甜品烘焙坊','食品'],
      ['p16','🧢','棒球帽 男女同款 遮阳防晒 显脸小 可调节',15.9,59,'4.1万',2,['9.9元包邮'],'基础款服饰店','服饰']
    ];
    return {
      products: P.map((x) => ({ id: x[0], em: x[1], img: '', title: x[2], price: x[3], orig: x[4],
                                sold: x[5], grp: x[6], tags: x[7], shop: x[8], cate: x[9], on: true })),
      banners: [],
      /* CHRIS_MALL_NAME_V1 商城名/标语：管理页可以改（用户要求「商城名」） */
      name: '星言商城',
      slogan: '拼着买 才便宜'
    };
  }
  function readMall() {
    const f = path.join(DATA_DIR, 'mall.json');
    const m = readJson(f, null);
    if (!m || !Array.isArray(m.products)) { const s0 = mallSeed(); writeJson(f, s0); return s0; }
    if (!Array.isArray(m.banners)) m.banners = [];
    if (typeof m.name !== 'string' || !m.name.trim()) m.name = '星言商城';   // CHRIS_MALL_NAME_V1
    if (typeof m.slogan !== 'string') m.slogan = '拼着买 才便宜';
    return m;
  }
  function saveMall(m) { writeJson(path.join(DATA_DIR, 'mall.json'), m); }
  if (parts[0] === 'mall' && method === 'GET') { ok(res, readMall()); return; }
  if (parts[0] === 'ops' && parts[1] === 'mall' && method === 'POST') {
    if (!isOpsUser(user)) return fail(res, 403, '没有权限');
    const b = await readBody(req);
    const m = readMall();
    const action = String(b.action || '').trim();
    if (action === 'product') {
      const it = b.item || {};
      const id = String(it.id || '').trim() || ('p' + Date.now().toString(36));
      const one = {
        id,
        em: String(it.em || '').slice(0, 8) || '📦',
        img: String(it.img || '').slice(0, 400),
        title: String(it.title || '').slice(0, 120) || '新商品',
        price: Math.max(0, Number(it.price) || 0),
        orig: Math.max(0, Number(it.orig) || 0),
        sold: String(it.sold || '').slice(0, 16) || '0',
        grp: Math.max(2, Math.min(9, Number(it.grp) || 2)),
        tags: Array.isArray(it.tags) ? it.tags.slice(0, 4).map((t) => String(t).slice(0, 12)) : [],
        shop: String(it.shop || '').slice(0, 40),
        cate: String(it.cate || '').slice(0, 20) || '其它',
        on: it.on === false ? false : true
      };
      const i = m.products.findIndex((x) => x.id === id);
      if (i >= 0) m.products[i] = one; else m.products.unshift(one);
      saveMall(m); ok(res, m); return;
    }
    if (action === 'remove') {
      const id = String(b.id || '');
      m.products = m.products.filter((x) => x.id !== id);
      saveMall(m); ok(res, m); return;
    }
    if (action === 'settings') {                       // CHRIS_MALL_NAME_V1 改商城名/标语
      if (b.name !== undefined) m.name = String(b.name).slice(0, 24).trim() || m.name;
      if (b.slogan !== undefined) m.slogan = String(b.slogan).slice(0, 40).trim();
      saveMall(m); ok(res, m); return;
    }
    if (action === 'banners') {
      m.banners = Array.isArray(b.banners) ? b.banners.slice(0, 8).map((u) => String(u).slice(0, 400)) : m.banners;
      saveMall(m); ok(res, m); return;
    }
    return fail(res, 400, 'action 不对');
  }

  /* 小店：商品 + 我的订单 */
  if (parts[0] === 'shop' && method === 'GET') {
    const cfg = readShopCfg();
    const items = cfg.items.filter((x) => x.on !== false)
      .sort((a, b) => (Number(a.sort) || 0) - (Number(b.sort) || 0))
      .map((x) => ({ id: x.id, name: x.name, price: Number(x.price) || 0, img: x.img || '',
                     kind: x.kind || 'physical', desc: x.desc || '', stock: Number(x.stock) || 0 }));
    const orders = loadOrders().filter((o) => o.userId === user.id).slice(0, 30);
    ok(res, { items, orders, balance: Number(user.balance) || 0 });
    return;
  }
  /* 小店：下单（零钱扣款） */
  if (parts[0] === 'shop' && parts[1] === 'order' && method === 'POST') {
    const b = await readBody(req);
    const cfg = readShopCfg();
    const it = cfg.items.find((x) => x.id === String(b.itemId || '') && x.on !== false);
    if (!it) return fail(res, 404, '这个商品不在架上了');
    const count = Math.max(1, Math.min(99, Number(b.count) || 1));
    const total = Math.round((Number(it.price) || 0) * count * 100) / 100;
    const bal = Number(user.balance) || 0;
    if (bal < total) return fail(res, 400, '零钱不够（还差 ' + money(total - bal) + '），去「我 → 服务 → 充值余额」');
    /* 有支付密码的用户：传了就必须对；没传（比如小额/调试）先放行，App 那边会主动弹密码框 */
    if (user.payPassword && b.payPassword && String(b.payPassword) !== String(user.payPassword)) {
      return fail(res, 400, '支付密码不对');
    }
    user.balance = Math.round((bal - total) * 100) / 100;
    if (it.stock !== undefined && it.stock !== null && it.stock !== '') it.stock = Math.max(0, (Number(it.stock) || 0) - count);
    saveShopCfg(cfg);
    saveUsers();
    sendTo(user.id, { type: 'balance', balance: user.balance });
    const order = { id: uid('od'), userId: user.id, kind: it.kind || 'physical', itemId: it.id,
                    name: it.name + (count > 1 ? (' ×' + count) : ''), price: total,
                    address: String(b.address || ''), at: now(), status: '已下单' };
    const orders = loadOrders(); orders.unshift(order); saveOrders(orders.slice(0, 500));
    ok(res, { order, balance: user.balance });
    return;
  }
  /* 卡包：我的卡券（优惠券 / 会员卡 / 礼品卡 / 票） */
  if (parts[0] === 'cards' && method === 'GET') {
    const mine = readCards().cards.filter((c) => c.userId === user.id)
      .sort((a, b) => String(b.createdAt || '').localeCompare(String(a.createdAt || '')));
    ok(res, { cards: mine });
    return;
  }
  /* 卡包：我自己核销一张（商家扫码那条路由商家侧来做） */
  if (parts[0] === 'cards' && parts[1] === 'use' && method === 'POST') {
    const b = await readBody(req);
    const c = readCards();
    const one = c.cards.find((x) => x.id === String(b.id || '') && x.userId === user.id);
    if (!one) return fail(res, 404, '没有这张卡');
    if (one.used) return fail(res, 400, '这张卡已经用过了');
    one.used = true; one.usedAt = now();
    saveCards(c);
    ok(res, { card: one });
    return;
  }
  /* 管理：小店上架/下架/改价/改库存 + 卡包发卡/核销（只给 ops） */
  /* 管理：小店全部商品（含已下架的）—— 编辑页要能改上架开关 */
  /* 管理：红包封面（App 内 ops 账号）—— 和后台 manage.html 的「红包封面」是同一份数据。
     传的是整份 covers（封面就几张，整份覆盖最简单，也跟后台那套校验完全一致）。 */
  if (parts[0] === 'ops' && parts[1] === 'rpcovers' && method === 'GET') {
    if (!isOpsUser(user)) return fail(res, 403, '没有权限');
    ok(res, { covers: readRpCovers() });
    return;
  }
  if (parts[0] === 'ops' && parts[1] === 'rpcovers' && method === 'POST') {
    if (!isOpsUser(user)) return fail(res, 403, '没有权限');
    const b = await readBody(req);
    const next = {};
    if (Array.isArray(b.covers)) {
      next.covers = b.covers.slice(0, 40).map((c, i) => ({
        id: str(c && c.id, 30) || ('cv' + Date.now().toString().slice(-5) + i),
        name: str(c && c.name, 20) || ('封面 ' + (i + 1)),
        image: str(c && c.image, 300),
        thumb: str(c && (c.thumb || c.image), 300),
        color: /^#[0-9a-fA-F]{6}$/.test(String((c && c.color) || '')) ? String(c.color) : '#B3241C',
        enabled: !(c && c.enabled === false)
      })).filter((c) => c.image);
      if (!next.covers.length) next.covers = DEFAULT_RP_COVERS.covers;
    }
    if (b.defaultId !== undefined) next.defaultId = str(b.defaultId, 30);
    const saved = saveRpCovers(next);
    ok(res, { covers: saved });
    return;
  }
  /* 管理：改一个 ui.json 里的开关/数值（App 内 ops 账号）—— 比如「实名前先刷脸」realnameFace。
     /api/ui 每次现读文件，所以改完 App 重拉一次 UI 配置就生效。 */
  if (parts[0] === 'ops' && parts[1] === 'ui' && method === 'POST') {
    if (!isOpsUser(user)) return fail(res, 403, '没有权限');
    const b = await readBody(req);
    const key = String(b.key || '').trim();
    if (!/^[A-Za-z][A-Za-z0-9_]{0,40}$/.test(key)) return fail(res, 422, '键名不合法');
    let value = b.value;
    if (typeof value === 'string') {
      const n = Number(value);
      value = (value !== '' && !isNaN(n)) ? n : value;
    }
    if (!['number', 'string', 'boolean'].includes(typeof value)) return fail(res, 422, '值不合法');
    const file = path.join(DATA_DIR, 'ui.json');
    let ui = {};
    try { ui = JSON.parse(fs.readFileSync(file, 'utf8')) || {}; } catch (e) { ui = {}; }
    const before = ui[key];
    ui[key] = value;
    try { fs.copyFileSync(file, file + '.bak-ops' + Date.now().toString().slice(-6)); } catch (e) { }
    writeJson(file, ui);
    console.log('[管理] ui.' + key + ' ' + JSON.stringify(before) + ' -> ' + JSON.stringify(value));
    ok(res, { key: key, value: value });
    return;
  }
  /* App 日志 / 崩溃汇入（只有 App 内的 ops 账号能看）：
     手机上的崩溃、异常、体检上传都走 POST /api/clientlog 落到 data/client-errors.jsonl，
     这里按类型汇总 + 给最近几条（倒序），点开能看到完整调用栈。 */
  if (parts[0] === 'ops' && parts[1] === 'logs' && method === 'GET') {
    if (!isOpsUser(user)) return fail(res, 403, '没有权限');
    const limit = Math.min(200, Math.max(1, Number(query.get('limit')) || 50));
    const want = String(query.get('kind') || '').trim();
    let all = [];
    try {
      all = fs.readFileSync(path.join(DATA_DIR, 'client-errors.jsonl'), 'utf8')
        .split('\n').filter(Boolean).map((line) => {
          try { return JSON.parse(line); } catch (e) { return null; }
        }).filter(Boolean);
    } catch (e) { all = []; }
    const counts = {};
    all.forEach((r) => { const k = String(r.kind || '未分类'); counts[k] = (counts[k] || 0) + 1; });
    const kinds = Object.keys(counts).map((k) => ({ kind: k, n: counts[k] })).sort((a, b) => b.n - a.n);
    let list = all.slice().reverse();
    if (want) list = list.filter((r) => String(r.kind || '未分类').indexOf(want) >= 0);
    list = list.slice(0, limit).map((r) => ({
      id: String(r.id || ''), kind: String(r.kind || ''), text: String(r.text || '').slice(0, 1200),
      stack: String(r.stack || '').slice(0, 6000), app: String(r.app || ''), user: String(r.user || ''),
      ip: String(r.ip || ''), at: String(r.at || '')
    }));
    ok(res, { total: all.length, kinds: kinds, rows: list });
    return;
  }
  if (parts[0] === 'ops' && parts[1] === 'shop' && method === 'GET') {
    if (!isOpsUser(user)) return fail(res, 403, '没有权限');
    ok(res, { items: readShopCfg().items });
    return;
  }
  if (parts[0] === 'ops' && parts[1] === 'shop' && method === 'POST') {
    if (!isOpsUser(user)) return fail(res, 403, '没有权限');
    const b = await readBody(req);
    const cfg = readShopCfg();
    if (b.removeId) {
      cfg.items = cfg.items.filter((x) => x.id !== String(b.removeId));
    } else if (b.item && b.item.id) {
      const i = cfg.items.findIndex((x) => x.id === String(b.item.id));
      if (i >= 0) cfg.items[i] = Object.assign({}, cfg.items[i], b.item);
      else cfg.items.push(Object.assign({ id: uid('g'), kind: 'physical', on: true, stock: 999, sort: cfg.items.length }, b.item));
    } else if (b.newItem) {
      cfg.items.push(Object.assign({ id: uid('g'), kind: 'physical', on: true, stock: 999, sort: cfg.items.length }, b.newItem));
    }
    saveShopCfg(cfg);
    ok(res, { items: cfg.items });
    return;
  }
  if (parts[0] === 'ops' && parts[1] === 'cards' && method === 'POST') {
    if (!isOpsUser(user)) return fail(res, 403, '没有权限');
    const b = await readBody(req);
    const c = readCards();
    /* 按用户名 / 昵称找人（发卡前先搜人） */
    if (b.action === 'find') {
      const q = String(b.q || '').trim().toLowerCase();
      const all = readCards().cards;
      const rows = db.users
        .filter((u) => !u.bot)
        .filter((u) => !q || String(u.username || '').toLowerCase().indexOf(q) >= 0
                       || String(u.nickname || '').toLowerCase().indexOf(q) >= 0)
        .slice(0, 12)
        .map((u) => ({ id: u.id, username: u.username || '', nickname: u.nickname || '',
                       avatar: u.avatar || '', cards: all.filter((c) => c.userId === u.id).length }));
      ok(res, { users: rows });
      return;
    }
    /* 某个用户名下的卡（管理页要能看、能删） */
    if (b.action === 'list') {
      const target = findUser(String(b.userId || '')) || user;
      ok(res, { cards: readCards().cards.filter((c) => c.userId === target.id), userId: target.id });
      return;
    }
    if (b.action === 'delete' && b.id) {
      c.cards = c.cards.filter((x) => x.id !== String(b.id));
    } else if (b.action === 'issue') {
      const target = findUser(String(b.userId || '')) || user;
      c.cards.unshift({ id: uid('cd'), userId: target.id, kind: String(b.kind || 'coupon'),
                        title: String(b.title || '优惠券'), sub: String(b.sub || ''),
                        amount: Number(b.amount) || 0, code: String(b.code || uid('code')), used: false,
                        validTo: String(b.validTo || ''), note: String(b.note || ''), createdAt: now() });
    }
    saveCards(c);
    ok(res, { cards: c.cards.filter((x) => x.userId === (findUser(String(b.userId || '')) || user).id) });
    return;
  }

  if (parts[0] === 'ops') {
    await handleOps(req, res, parts, query);
    return;
  }

  /* ------------------------------------------------ 设备确认登录（仿扫码登录） */
  // 思路和 QQ 的扫码登录一样：这台设备出一个码，另一台已登录的设备确认，这台就登上了
  /* ------------------------------------------------ TRTC（腾讯云实时音视频）签名
     客户端进房要三样东西：sdkAppId、userId、userSig；房间号双方要一致。
     房间号按「会话 id」算：两个人拿同一个会话 id 算出来一定一样。
     密钥只在服务端，绝不下发。 */
  if (parts[0] === 'trtc' && parts[1] === 'sig' && method === 'GET') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const cfg = readTrtcCfg();
    if (!cfg.sdkAppId || !cfg.secretKey) return fail(res, 500, 'TRTC 还没配置（data/trtc.json 里填 sdkAppId 和 secretKey）');
    /* 语音这条的总开关：data/trtc.json 里写 "voiceEnabled": false，
       语音的签名请求直接失败，客户端自动退回自建转发通道（视频不受影响）。 */
    const wantMedia = String(query.get('media') || '').toLowerCase();
    if (wantMedia === 'audio' && cfg.voiceEnabled === false) {
      return fail(res, 503, '语音暂不走 TRTC（服务端 data/trtc.json 的 voiceEnabled 关掉了）');
    }
    const expire = Number(query.get('expire')) > 0 ? Number(query.get('expire')) : cfg.expireSeconds;
    const seed = String(query.get('room') || query.get('chat') || '').trim().slice(0, 80)
      || ('u' + me.id);
    const userSig = trtcUserSig(me.id, expire);
    if (!userSig) return fail(res, 500, 'TRTC 签名失败');
    return ok(res, {
      sdkAppId: cfg.sdkAppId,
      userId: me.id,
      userSig,
      roomId: trtcRoomId(seed),      // 数字房间号（TRTCParams.roomId 要的是 UInt32）
      roomStr: seed,                 // 原始那串（两边都用它算，方便排查）
      expire,
      expiresAt: Math.floor(Date.now() / 1000) + expire
    });
  }

  if (parts[0] === 'pair' && parts[1] === 'start' && method === 'POST') {
    prunePairCodes();
    let code = '';
    do { code = String(Math.floor(100000 + Math.random() * 900000)); } while (pairCodes.has(code));
    /* 发起登录的那台设备是谁：在手机上确认登录时要显示出来（微信的确认页也写设备名） */
    let stBody = {};
    try { stBody = await readBody(req); } catch (e) { stBody = {}; }
    const device = str(stBody.device, 40) || '新设备';
    /* 发起端能带上「以前登录过的账号名」的话，直接给这个账号已登录的手机推一条确认通知
       （微信也是新设备一发、老手机就弹）；带不上也没关系 —— 老手机扫二维码一样能确认。 */
    let hintUserId = '';
    const hintName = str(stBody.username, 24);
    if (hintName) {
      const hu = findUserByName(hintName);
      if (hu && !hu.bot && !hu.banned) hintUserId = hu.id;
    }
    pairCodes.set(code, { secret: uid('pair'), createdAt: Date.now(), expiresAt: Date.now() + PAIR_TTL_MS,
                          userId: null, approvedName: '', device, ip: clientInfo(req).ip, hintUserId });
    if (hintUserId) notifyPairRequest(hintUserId, code, device, '');
    ok(res, { code, expiresIn: Math.round(PAIR_TTL_MS / 1000) });
    return;
  }

  /* 确认方先看一眼：这是哪台设备在请求登录（微信确认页会写设备名 + 时间） */
  if (parts[0] === 'pair' && parts[1] === 'info' && method === 'GET') {
    prunePairCodes();
    const ic = str(query.get('code'), 10);
    const irec = pairCodes.get(ic);
    if (!irec) return ok(res, { status: 'expired' });
    /* 谁在查这个码 = 谁要确认（已登录的那台）。顺手给他**其它**已登录设备也推一条，
       这样另一台手机点通知就能直接进「登录确认」卡片，不用手输数字。 */
    const cuPair = currentUser(req);
    if (cuPair) notifyPairRequest(cuPair.id, ic, irec.device || '新设备', clientInfo(req).deviceId);
    ok(res, { status: 'pending', device: irec.device || '新设备', ip: irec.ip || '',
              at: new Date(irec.createdAt).toISOString() });
    return;
  }

  if (parts[0] === 'pair' && parts[1] === 'status' && method === 'GET') {
    prunePairCodes();
    const rec = pairCodes.get(str(query.get('code'), 10));
    if (!rec) return ok(res, { status: 'expired' });
    if (!rec.userId) return ok(res, { status: 'pending' });
    const u = findUser(rec.userId);
    if (!u) { pairCodes.delete(str(query.get('code'), 10)); return ok(res, { status: 'expired' }); }
    pairCodes.delete(str(query.get('code'), 10));   // 一次性
    /* 这台新设备刚刚登录成功：记进设备表（型号 / 系统 / 最后登录时间） */
    try { rememberDevice(u, req); saveUsers(); } catch (e) { }
    ok(res, { status: 'approved', user: publicUser(u) },
      { 'Set-Cookie': sessionCookie(signToken(u.id, req), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  if (parts[0] === 'captcha' && method === 'GET') {
    const cap = makeCaptcha();
    ok(res, { id: cap.id, svg: cap.svg, expiresIn: Math.round(CAPTCHA_TTL_MS / 1000) });
    return;
  }

  /* 登录滑动验证：① 领题 */
  if (parts[0] === 'slider' && parts.length === 1 && method === 'GET') {
    const ip = clientInfo(req).ip;
    if (!sliderRateAllow(ip)) return fail(res, 429, '换题太频繁了，歇一会儿再试');
    ok(res, makeSliderChallenge());
    return;
  }

  /* 登录滑动验证：② 交卷（位置对上了给一次性通行证） */
  if (parts[0] === 'slider' && parts[1] === 'verify' && method === 'POST') {
    const body = await readBody(req);
    const r = checkSlider(str(body.id, 60), body.x, body.y);
    if (r.error) return fail(res, 400, r.error);
    ok(res, { ticket: r.ticket, expiresIn: r.expiresIn });
    return;
  }

  if (parts[0] === 'version' && method === 'GET') {
    /* 后台「App 版本管理」配的那份也一起下发：App 启动时拉这个就能做
       「有新版本」「强制更新」提示（和微信一样），不用重新发版才能改。 */
    const v = imAdminCfg().version || {};
    ok(res, {
      version: assetVersion(),
      startedAt: new Date(Date.now() - process.uptime() * 1000).toISOString(),
      app: {
        version: v.version || '',
        notes: v.notes || '',
        force: !!v.force,
        url: v.url || 'https://aa.x8iu.com/Luchat.ipa',
        downloadPage: v.downloadPage || 'https://aa.x8iu.com'
      },
      notice: (() => {
        const n = imAdminCfg().notice || {};
        return n.enabled === true ? {
          title: n.title || '', content: n.content || '', kind: n.kind || 'popup',
          startAt: n.startAt || '', endAt: n.endAt || '',
          minVersion: n.minVersion || '', maxVersion: n.maxVersion || ''
        } : null;
      })()
    });
    return;
  }

  if (method === 'OPTIONS') {
    res.writeHead(204, { Allow: 'GET,POST,PATCH,DELETE,OPTIONS' });
    res.end();
    return;
  }

  /* 登录前只开放这几个接口（登录页要用的），其它一律要求先登录。
     这样没账号的黑客连「发现页配了什么、我页配了什么、礼物有哪些」都看不到。 */
  const PUBLIC_API = ['captcha', 'version', 'health', 'lan', 'branding', 'ui', 'badges', 'endpoints', 'register', 'login', 'logout', 'session', 'pair', 'unban', 'account', 'which', 'qr', 'clientlog'];   // CHRIS_FREEZE_V1 加了 account
  if (PUBLIC_API.indexOf(parts[0]) < 0) {
    if (!currentUser(req)) {
      /* 手机在别处登录了（令牌作废）：回一个明确的 code，App 弹「已在别处登录」卡片 */
      if (req.__otherLogin) return fail(res, 401, '你的账号在另一台设备上登录了', { code: 'other_login' });
      /* 只有「压根没带令牌」的裸请求才算异常（扫描器）。
         令牌过期是正常现象 —— 以前一律记 strike，会话一过期 App 每次轮询都记一笔，
         60 笔就把整个 IP 封了（用户看到的就是「完全进不去」）。 */
      if (!req.headers.authorization && !req.headers.cookie) {
        strikeIp(clientInfo(req).ip, '裸请求取数据 ' + parts[0]);
      }
      return fail(res, 401, '请先登录');
    }
  }
  /* 青少年模式：开了以后按后台（家长）勾选的项，把这些接口直接挡住 */
  {
    const cu = currentUser(req);
    if (cu) {
      /* 设备表里的「最后活跃时间」：同一台设备最多每 20 分钟写一次 */
      try {
        const info0 = clientInfo(req);
        if (info0.deviceId) {
          const list0 = Array.isArray(cu.devices) ? cu.devices : [];
          const hit0 = list0.filter((d) => (d.id || '') === info0.deviceId)[0];
          if (hit0) {
            if (Date.now() - msOf(hit0.at) > 20 * 60 * 1000) {
              hit0.at = now();
              hit0.ip = info0.ip || hit0.ip;
              if (info0.model) hit0.model = friendlyModelName(info0.model);
              if (info0.os) hit0.os = info0.os;
              saveUsers();
            }
          } else if (list0.length) {
            /* 新设备登录：给用户发一条系统通知（和微信团队一样） */
            try {
              const i1 = clientInfo(req);
              sysNotice(cu.id, '你的账号在' + (i1.model ? friendlyModelName(i1.model) : '新设备')
                + '上登录了（' + (i1.os || '') + '，IP ' + (i1.ip || '') + '）。不是你操作的？去「我 → 设置 → 账号与安全 → 登录设备管理」看看。', '登录提醒', 'login');
            } catch (e) {}
            rememberDevice(cu, req);
            saveUsers();
          }
        }
      } catch (e) { }
      const blocked = teenBlocked(cu, parts, method);
      if (blocked) return fail(res, 403, blocked);
    }
  }

  if (parts[0] === 'health') { ok(res, { service: 'chris-chat', time: now() }); return; }

  /* App 崩溃上报：写进 data/client-errors.jsonl（手机上崩了，电脑这边能看到调用栈） */
  if (parts[0] === 'clientlog' && method === 'POST') {
    const body = await readBody(req);
    const row = {
      id: uid('err'),
      kind: str(body.kind, 30), text: str(body.text, 4000), stack: str(body.stack, 6000),
      lang: str(body.lang, 8), app: str(body.app, 20),
      ip: clientInfo(req).ip,
      user: (currentUser(req) || {}).username || '',
      at: str(body.at, 30) || now()
    };
    try {
      fs.appendFileSync(path.join(DATA_DIR, 'client-errors.jsonl'), JSON.stringify(row) + '\n', 'utf8');
    } catch (err) { /* 写不了就算了，别把崩溃变成第二个崩溃 */ }
    console.log('[崩溃上报] ' + row.kind + ' ' + row.text.slice(0, 200));
    ok(res, { logged: true });
    return;
  }

  /* ------------------------------------------------ 客服中心（用户侧）
     App「设置 → 帮助与反馈 → 客服中心」用：常见问题（后台可改）+ 在线客服（转人工）+ 我的工单 */
  if (parts[0] === 'support' && method === 'GET') {
    const me = currentUser(req);
    const cfg = readSupport();
    const agent = supportAgent();
    ok(res, {
      title: cfg.title || '客服中心',
      searchHint: cfg.searchHint || '',
      human: cfg.human !== 0,
      ticketOn: cfg.ticketOn !== 0,
      phone: cfg.phone || '',
      email: cfg.email || '',
      workTime: cfg.workTime || '',
      greet: cfg.greet || '',
      ticketHint: cfg.ticketHint || '',
      categories: (cfg.categories || []).map((c) => ({
        id: c.id || '',
        title: c.title || '',
        icon: c.icon || '',
        items: (c.items || []).filter((it) => it && it.q).map((it) => ({ q: it.q, a: it.a || '' }))
      })).filter((c) => c.items.length),
      agent: { id: agent.id, nickname: agent.nickname || '在线客服', avatar: agent.avatar || '' },
      tickets: readSupportTickets(50, me.id)
    });
    return;
  }

  /* 提交问题 → 生成一张工单（后台「客服中心 → 工单」里能看能回） */
  if (parts[0] === 'support' && parts[1] === 'ticket' && method === 'POST') {
    const me = currentUser(req);
    const cfg = readSupport();
    if (cfg.ticketOn === 0) return fail(res, 403, '暂时不能提交问题，先用在线客服');
    const body = await readBody(req);
    const content = str(body.content, 1000).trim();
    if (!content) return fail(res, 422, '把遇到的问题写一句再提交');
    const ticket = {
      id: uid('tk'),
      userId: me.id,
      username: me.username || '',
      nickname: me.nickname || '',
      category: str(body.category, 30) || '其它问题',
      title: str(body.title, 60) || content.slice(0, 24),
      content: content,
      contact: str(body.contact, 60) || '',
      status: 'pending',            // pending 待处理 / done 已处理
      reply: '',
      createdAt: now(),
      repliedAt: '',
      doneAt: ''
    };
    appendSupportTicket(ticket);
    ok(res, { ticket, tickets: readSupportTickets(50, me.id) });
    return;
  }

  /* 转人工：和「在线客服」开一个会话（已有就直接用），第一条自动发欢迎语 */
  if (parts[0] === 'support' && parts[1] === 'human' && method === 'POST') {
    const me = currentUser(req);
    const cfg = readSupport();
    if (cfg.human === 0) return fail(res, 403, '在线客服暂时没开，先看看常见问题');
    const agent = supportAgent();
    const chat = supportChatFor(me.id);
    let msgs = [];
    try { msgs = loadMessages(chat.id); } catch (e) { msgs = []; }
    if (!msgs.length && cfg.greet) {
      try { deliverMessage(agent, chat.id, 'text', cfg.greet, null); } catch (e) { }
    }
    ok(res, {
      chatId: chat.id,
      agent: { id: agent.id, nickname: agent.nickname || '在线客服', avatar: agent.avatar || '' }
    });
    return;
  }

  /* 二维码：/api/qr?text=xxx 直接回一段 SVG（群二维码、授权登录都用它） */
  if (parts[0] === 'qr' && method === 'GET') {
    const text = str(query.get('text'), 300);
    if (!text) return fail(res, 422, '缺少 text');
    const svg = QR.svg(text, Number(query.get('scale')) || 6);
    if (!svg) return fail(res, 422, '内容太长，二维码放不下');
    const enc = QR.encode(text);
    ok(res, {
      svg: svg, text: text,
      rows: enc ? enc.modules.map((r) => r.join('')) : [], size: enc ? enc.size : 0
    });
    return;
  }
  // 前端资源版本号（手机端定时比对，发现变了就自动刷新，省得手动清缓存）
  if (parts[0] === 'version' && method === 'GET') { ok(res, { version: assetVersion() }); return; }

  /* App 安装包的限时签名链接（要登录）：
     App 里点「立即更新」用这条链接，安装包直链就能随时收口，改成 gated 也不影响老用户更新。 */
  if (parts[0] === 'app' && parts[1] === 'download' && method === 'GET') {
    ok(res, {
      url: appDownloadUrl(req),
      expiresIn: Math.round(APP_DOWNLOAD_TTL_MS / 1000),
      open: appDownloadOpen()
    });
    return;
  }

  // 手机访问用的局域网地址（登录页也要用，所以不校验登录）
  if (parts[0] === 'lan' && method === 'GET') {
    const urls = [];
    try {
      const nets = os.networkInterfaces();
      Object.keys(nets).forEach((name) => {
        (nets[name] || []).forEach((n) => {
          if (n.family === 'IPv4' && !n.internal) urls.push({ name, ip: n.address, url: 'http://' + n.address + ':' + PORT + '/' });
        });
      });
    } catch (err) { /* 忽略 */ }
    ok(res, { port: PORT, urls });
    return;
  }

  // 界面配置公开：登录页也要用它来显示自定义图标和应用名
  if (parts[0] === 'branding' && method === 'GET') {
    /* ICE 配置里可以写 __HOST__ 占位符：出站时换成服务器自己的局域网地址，
       这样内置 TURN 的地址永远对（换网络/换机器都不用改配置）。 */
    const b = Object.assign({}, db.branding);
    if (b.iceServers && String(b.iceServers).indexOf('__HOST__') >= 0) {
      b.iceServers = String(b.iceServers).replace(/__HOST__/g, primaryLanIp());
    }
    /* 登录滑动验证开着没：客户端按它决定要不要先让用户拖滑块
       （关掉的开关在 data/security.json 的 sliderLogin） */
    b.sliderLogin = !!secCfg().sliderLogin;
    ok(res, { branding: b });
    return;
  }

  /* App 的「界面配置」：改 data/ui.json 里的数字/颜色，App 重开一次就生效，不用重装。
     每次请求都重新读文件，所以改完不用重启服务。 */
  /* 红点提醒配置（App 底栏和列表行按它显示） */
  if (parts[0] === 'badges' && method === 'GET') {
    ok(res, { badges: db.badges || BADGE_DEFAULT });
    return;
  }

  /* 搜索页的「猜你想搜」：后台 data/search-hot.json 里配词（words: [...]），
     App 进搜索页拉一次；改完不用出包。没配就给内置那组。 */
  if (parts[0] === 'search-hot' && method === 'GET') {
    const cfg = readJson(path.join(DATA_DIR, 'search-hot.json'), { words: null });
    const def = ['朋友圈', '聊天记录', '公众号', '视频号', '附近的人', '群聊'];
    const words = Array.isArray(cfg.words) && cfg.words.length
      ? cfg.words.map((w) => String(w || '').trim()).filter(Boolean).slice(0, 20)
      : def;
    ok(res, { words });
    return;
  }

  /* 多入口：App 每次进前台拉一次，主入口连不上时按这张表自动换线路。
     放在公开接口里（还没登录也要能拿到），后台「线路入口」页可以随时改。 */
  if (parts[0] === 'endpoints' && method === 'GET') {
    ok(res, { endpoints: serverEndpoints() });
    return;
  }

  if (parts[0] === 'ui' && method === 'GET') {
    let ui = {};
    try {
      ui = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'ui.json'), 'utf8')) || {};
    } catch (err) { ui = {}; }
    /* UI 图标的自定义（后台「UI 图标」页换过的）：App 一打开就拉一份，直接用新的 */
    let icons = {};
    try {
      icons = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'icons.json'), 'utf8')) || {};
    } catch (err) { icons = {}; }
    /* 按版本回落：换成「自定义 SVG」的那批图标，B856 之前的 App 解析器不认
       fill-rule=evenodd —— 现成图标集（Iconly 这类）是用「一条 path + 奇偶挖空」
       画轮廓的，老解析器只会按默认规则填，会把齿轮中间的孔、放大镜的圈糊成实心块。
       所以老版本一律不发 SVG 覆盖，让它们继续用内置图标（图片/emoji 那类照发）。 */
    const uiBuildNo = Number((String(req.headers['x-app-build'] || '').match(/B(\d+)/) || [])[1] || 0);
    const SVG_ICON_MIN_BUILD = 856;
    if (uiBuildNo && uiBuildNo < SVG_ICON_MIN_BUILD) {
      const kept = {};
      Object.keys(icons).forEach((k) => {
        if (!String(icons[k] || '').trim().startsWith('<svg')) kept[k] = icons[k];
      });
      icons = kept;
    }
    ok(res, { ui, icons });
    return;
  }

  /* 手机端把「真实量到的尺寸」报回来，方便对着参考图校准（只写 data/measure.json） */
  /* ---------------- 附近的人：报位置 ---------------- */
  /* 位置搜索：后台填了高德 Key 就用高德的 POI（国内比苹果地图准很多），
     没填就返回 503，客户端会自动退回系统地图搜索。 */
  if (parts[0] === 'geo' && parts[1] === 'search' && method === 'GET') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const key = String(readGeo().amapKey || '').trim();
    if (!key) return fail(res, 503, '还没配高德 Key（后台「地图」里填）');
    const q = str(query.get('q'), 60);
    const lat = Number(query.get('lat')) || 0;
    const lng = Number(query.get('lng')) || 0;
    const around = lat !== 0 && lng !== 0;
    const url = around
      ? 'https://restapi.amap.com/v3/place/around?key=' + encodeURIComponent(key)
        + '&location=' + lng + ',' + lat + '&keywords=' + encodeURIComponent(q || '')
        + '&radius=3000&offset=20&page=1&extensions=base'
      : 'https://restapi.amap.com/v3/place/text?key=' + encodeURIComponent(key)
        + '&keywords=' + encodeURIComponent(q || '') + '&offset=20&page=1&extensions=base';
    try {
      const r = await fetch(url, { signal: AbortSignal.timeout(9000) });
      const d = await r.json();
      const pois = (d && d.pois) || [];
      ok(res, {
        source: 'amap',
        places: pois.map((p) => {
          const ll = String(p.location || '').split(',');
          const gLng = Number(ll[0]) || 0;
          const gLat = Number(ll[1]) || 0;
          const w = gcj02ToWgs84(gLat, gLng);
          const addr = String(p.address || '') ||
            (String(p.pname || '') + String(p.cityname || '') + String(p.adname || ''));
          return { name: String(p.name || ''), addr: addr, lat: w.lat, lng: w.lng };
        }).filter((x) => x.name && x.lat && x.lng)
      });
    } catch (e) {
      return fail(res, 502, '高德查询失败：' + String((e && e.message) || e).slice(0, 60));
    }
    return;
  }

  if (parts[0] === 'nearby' && parts.length === 1 && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const lat = Number(body.lat);
    const lng = Number(body.lng);
    if (!isFinite(lat) || !isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      return fail(res, 422, '定位不合法');
    }
    const map = loadNearby();
    map[user.id] = { lat: lat, lng: lng, at: Date.now(), visible: body.visible !== false };
    pruneNearby();
    saveNearby();
    ok(res, { located: true });
    return;
  }

  /* ---------------- 附近的人：名单 ---------------- */
  /* 清除自己的位置（微信那个「清除位置信息并退出」）：直接从名单里消失 */
  if (parts[0] === 'nearby' && parts.length === 1 && method === 'DELETE') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const map = loadNearby();
    if (map[user.id]) { delete map[user.id]; saveNearby(); }
    ok(res, { cleared: true });
    return;
  }

  if (parts[0] === 'nearby' && parts.length === 1 && method === 'GET') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const lat = Number(query.get('lat'));
    const lng = Number(query.get('lng'));
    const gender = String(query.get('gender') || 'all');
    const limit = Math.min(80, Number(query.get('limit')) || 60);
    /* 默认只看 5 公里；客户端想放宽（比如 5 公里没人）可以传 maxKm=20 */
    const maxRaw = Number(query.get('maxKm'));
    const maxKm = (isFinite(maxRaw) && maxRaw >= 0.5) ? Math.min(100, maxRaw) : NEARBY_MAX_KM;
    const map = loadNearby();
    pruneNearby();
    /* 自己的位置：优先用请求里带的（刚定位完更准），没有就用上次上报的 */
    const mine = (isFinite(lat) && isFinite(lng))
      ? { lat: lat, lng: lng }
      : (map[user.id] ? { lat: map[user.id].lat, lng: map[user.id].lng } : null);
    const friends = new Set(friendIds(user.id));
    const rows = [];
    Object.keys(map).forEach((id) => {
      if (id === user.id) return;
      const rec = map[id];
      const u = findUser(id);
      if (!u || u.banned || u.bot || rec.visible === false) return;
      if ((gender === 'male' || gender === 'female') && (u.gender || 'male') !== gender) return;
      const km = mine ? nearbyKm(mine, rec) : null;
      rows.push({ u: u, km: km, at: rec.at });
    });
    rows.sort((a, b) => (a.km == null ? 1e9 : a.km) - (b.km == null ? 1e9 : b.km));
    const near = rows.filter((x) => x.km == null || x.km <= maxKm);
    /* 5 公里内没人时，顺手算一下 20 公里内有几个，好让客户端提示「扩大范围」 */
    const wider20 = rows.filter((x) => x.km != null && x.km <= 20).length;
    ok(res, {
      me: mine ? { lat: mine.lat, lng: mine.lng } : null,
      maxKm: maxKm,
      wider: wider20,
      people: near.slice(0, limit).map((x) => ({
        id: x.u.id,
        nickname: x.u.nickname || x.u.username || '附近的人',
        avatar: x.u.avatar || '',
        gender: x.u.gender || '',
        region: x.u.region || '',
        bio: x.u.bio || '',
        moodText: x.u.moodText || '',
        moments: (db.moments || []).filter((m) => m.authorId === x.u.id && m.status !== 'pending').length,
        online: connections.has(x.u.id),
        friend: friends.has(x.u.id),
        km: x.km == null ? null : Math.round(x.km * 10) / 10,
        minutes: Math.max(0, Math.round((Date.now() - x.at) / 60000))
      }))
    });
    return;
  }

  /* ---------------- 附近的人：打招呼（发一条消息，会话就出来了） ---------------- */
  /* ---------------- 摇一摇：摇一下，找同时在摇的人 ---------------- */
  /* 通话诊断：App 连不上时把 ICE 状态报回来，写进 call-trace.log，方便查「一直正在接通」 */
  if (parts[0] === 'call-diag' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    callTrace('diag ' + (user.nickname || user.username) + '：' + str(body.text, 400));
    ok(res, { saved: true });
    return;
  }

  /* ---------------- 直播专场：房间列表 / 进房间 / 弹幕 / 点赞 ----------------
     没有真视频（内网演示服跑不动推流），但「谁在看、谁在说话、多少赞」都是真的：
     进房间会记人数，弹幕和点赞通过长连接实时广播给同房间的人。 */
  if (parts[0] === 'live' && parts.length === 1 && method === 'GET') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const cfg = readJson(path.join(DATA_DIR, 'live.json'), { rooms: [] });
    const rooms = (cfg.rooms || []).map((r) => {
      const host = findUser(r.host) || db.users.find((u) => (u.nickname || '') === r.host);
      const watching = liveViewers.get(r.id);
      return {
        id: r.id, title: r.title, tag: r.tag || '', cover: r.cover || '',
        status: r.status === 'live' ? 'live' : 'soon',
        hot: Number(r.hot) || 0,
        watching: watching ? watching.size : 0,
        likes: liveLikes.get(r.id) || 0,
        /* 有没有人在真推流（有就能看实时画面） */
        hostId: liveHosts.get(r.id) || '',
        streaming: !!liveHosts.get(r.id),
        host: {
          id: host ? host.id : '',
          name: (host && host.nickname) || r.host || '主播',
          avatar: (host && host.avatar) || ''
        }
      };
    });
    ok(res, { rooms: rooms });
    return;
  }

  if (parts[0] === 'live' && parts[2] === 'join' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const id = str(parts[1], 40);
    if (!liveViewers.has(id)) liveViewers.set(id, new Set());
    const set = liveViewers.get(id);
    set.add(user.id);
    liveBroadcast(id, { type: 'live', action: 'count', roomId: id, watching: set.size });
    ok(res, { roomId: id, watching: set.size });
    return;
  }

  if (parts[0] === 'live' && parts[2] === 'leave' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const id = str(parts[1], 40);
    const set = liveViewers.get(id);
    if (set) {
      set.delete(user.id);
      liveBroadcast(id, { type: 'live', action: 'count', roomId: id, watching: set.size });
    }
    ok(res, { left: true });
    return;
  }

  if (parts[0] === 'live' && parts[2] === 'danmaku' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const id = str(parts[1], 40);
    const body = await readBody(req);
    const text = str(body.text, 80);
    if (!text) return fail(res, 422, '说点什么吧');
    const word = sensitiveHit(text);
    if (word) {
      recordViolation(user, null, text, word);
      return fail(res, 422, '这条弹幕里有敏感词，换个说法吧');
    }
    liveBroadcast(id, {
      type: 'live', action: 'danmaku', roomId: id,
      from: user.nickname || user.username, fromId: user.id, text: text, at: now()
    });
    ok(res, { sent: true });
    return;
  }

  if (parts[0] === 'live' && parts[2] === 'like' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const id = str(parts[1], 40);
    liveLikes.set(id, (liveLikes.get(id) || 0) + 1);
    liveBroadcast(id, { type: 'live', action: 'like', roomId: id, likes: liveLikes.get(id), from: user.nickname || '' });
    ok(res, { likes: liveLikes.get(id) });
    return;
  }

  /* ---------------- 游戏页：只发列表，玩法在客户端 ---------------- */
  /* 读某条视频的评论列表（客户端点开评论面板时用）。
     注意：必须放在下面的 feed GET 之前 —— 那个路由不校验子路径，
     放后面的话 /api/feed/comments 会被当成"拉推荐流"。 */
  if (parts[0] === 'feed' && parts[1] === 'comments' && method === 'GET') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const id = str(query.get('id'), 40);
    if (!id) return fail(res, 422, '缺少 id');
    const f0 = readJson(path.join(DATA_DIR, 'feed.json'), { items: [], posts: [] });
    const it0 = (f0.posts || []).concat(f0.items || []).find((x) => x.id === id);
    if (!it0) return fail(res, 404, '这条视频不在了');
    const list0 = (Array.isArray(it0.comments) ? it0.comments : []).map((c) => {
      const u = c.userId ? findUser(c.userId) : null;
      return {
        id: c.id,
        userId: c.userId || '',
        name: (u && u.nickname) || c.name || '用户',
        avatar: (u && u.avatar) || '',
        text: c.text || '',
        at: c.at || ''
      };
    }).reverse();                      // 新的在上面
    ok(res, { comments: list0, count: list0.length + (Number(it0.baseComments) || 0) });
    return;
  }

  /* 取一整套短剧的全部集数（客户端「选集」面板用）。
     剧集可能被拆在不同的推荐批次里，所以这里直接按剧集 id 捞全。 */
  if (parts[0] === 'feed' && parts[1] === 'series' && method === 'GET') {
    const userS = currentUser(req);
    if (!userS) return fail(res, 401, '请先登录');
    const sid = str(query.get('id'), 60);
    if (!sid) return fail(res, 422, '缺少 id');
    const fs0 = readJson(path.join(DATA_DIR, 'feed.json'), { items: [], posts: [] });
    const epsAll = (fs0.items || []).concat(fs0.posts || []).filter((x) => String(x.series || '') === sid);
    const epNum = (x) => { const m = String(x.ep || '').match(/([0-9]+)/); return m ? Number(m[1]) : 999; };
    epsAll.sort((a, b) => epNum(a) - epNum(b));
    ok(res, {
      series: sid,
      name: (epsAll[0] && epsAll[0].seriesName) || '',
      items: epsAll.map((it) => feedItemOut(it, userS))
    });
    return;
  }

  /* ---------------- 视频号（抖音式竖屏 feed） ----------------
     items = 后台内置的（data/feed.json），posts = 用户自己发的；
     点赞/评论都落在同一个文件里，重启不丢。 */
  if (parts[0] === 'feed' && method === 'GET') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const f = readJson(path.join(DATA_DIR, 'feed.json'), { items: [], posts: [] });
    /* mine=1：只要自己发布的作品（「我 → 作品」那一页用），后台内置的那些不算作品 */
    const onlyMine = query.get('mine') === '1';
    /* 三个 tab（和微信视频号一致）：
         recommend 推荐 —— 抖音那套：全部作品按「热度 + 新鲜度」打分，每次刷新顺序会变
         follow    关注 —— 我关注的人（这里=我的好友）发的作品，按时间倒序
         friends   朋友 —— 我的好友点过赞的作品（微信「朋友」就是这个逻辑） */
    const tab = str(query.get('tab'), 12) || (onlyMine ? '' : 'recommend');
    const myFriends = new Set(friendIds(user.id));
    const mineOnly = onlyMine
      ? (f.posts || []).filter((it) => it.authorId === user.id)
      : null;
    let all;
    if (mineOnly) {
      all = mineOnly;
    } else if (tab === 'follow') {
      /* 关注：真的关注表（feed-follows.json）里那些人发的作品。
         一条都没关注过的时候，退回「好友发的」——不然这个 tab 是空的，看着像坏了。 */
      const followed = myFeedFollows(user.id);
      if (followed.length) {
        const set = new Set(followed);
        all = (f.posts || []).filter((it) => it.authorId && set.has(it.authorId));
      } else {
        all = (f.posts || []).filter((it) => it.authorId && myFriends.has(it.authorId));
      }
      all.sort((a, b) => String(b.createdAt || '').localeCompare(String(a.createdAt || '')));
    } else if (tab === 'friends') {
      all = (f.posts || []).filter((it) => (it.likedBy || []).some((id) => myFriends.has(id)));
      all.sort((a, b) => String(b.createdAt || '').localeCompare(String(a.createdAt || '')));
    } else {
      /* 推荐：抖音那套「千人千面」——兴趣 / 社交 / 负反馈 / 多样性 / 探索 */
      all = rankFeedFor(user, (f.posts || []).concat(f.items || []), myFriends);
    }
    const out = all.map((it) => feedItemOut(it, user));
    const cfg0 = readJson(path.join(DATA_DIR, 'feed.json'), {});
    ok(res, {
      items: out,
      style: Object.assign({}, FEED_STYLE_DEFAULT, cfg0.style || {}),
      flags: Object.assign({}, FEED_FLAGS_DEFAULT, cfg0.flags || {})
    });
    return;
  }

  /* 视频号：关注 / 取消关注（真的关注表，和好友关系分开） */
  if (parts[0] === 'feed' && parts[1] === 'follow' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const target = findUser(str(body.userId, 40));
    if (!target) return fail(res, 404, '用户不存在');
    if (target.id === user.id) return fail(res, 422, '不能关注自己');
    const dbm = readFeedFollows();
    const on = body.follow !== false;
    const idx = dbm.follows.findIndex((f) => f.fromId === user.id && f.toId === target.id);
    if (on && idx < 0) dbm.follows.push({ fromId: user.id, toId: target.id, at: now() });
    if (!on && idx >= 0) dbm.follows.splice(idx, 1);
    feedFollowCache = dbm;
    saveFeedFollows();
    ok(res, { following: on, count: myFeedFollows(user.id).length });
    return;
  }

  if (parts[0] === 'feed' && parts[1] === 'like' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const id = str(body.id, 40);
    const file = path.join(DATA_DIR, 'feed.json');
    const f = readJson(file, { items: [], posts: [] });
    const list = (f.posts || []).concat(f.items || []);
    const it = list.find((x) => x.id === id);
    if (!it) return fail(res, 404, '这条视频不在了');
    const likedBy = Array.isArray(it.likedBy) ? it.likedBy : [];
    const i = likedBy.indexOf(user.id);
    if (i >= 0) likedBy.splice(i, 1); else likedBy.push(user.id);
    it.likedBy = likedBy;
    writeJson(file, f);
    ok(res, { liked: i < 0, likes: likedBy.length + (Number(it.baseLikes) || 0) });
    return;
  }

  /* 收藏：和点赞一样，谁收藏了记在条目里（savedBy），可以取消 */
  if (parts[0] === 'feed' && parts[1] === 'favorite' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const id = str(body.id, 40);
    const file = path.join(DATA_DIR, 'feed.json');
    const f = readJson(file, { items: [], posts: [] });
    const list = (f.posts || []).concat(f.items || []);
    const it = list.find((x) => x.id === id);
    if (!it) return fail(res, 404, '这条视频不在了');
    const savedBy = Array.isArray(it.savedBy) ? it.savedBy : [];
    const i = savedBy.indexOf(user.id);
    if (i >= 0) savedBy.splice(i, 1); else savedBy.push(user.id);
    it.savedBy = savedBy;
    writeJson(file, f);
    ok(res, { favorited: i < 0, favorites: savedBy.length });
    return;
  }

  if (parts[0] === 'feed' && parts[1] === 'comment' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const id = str(body.id, 40);
    const text = str(body.text, 120);
    if (!text) return fail(res, 422, '说点什么吧');
    const word = sensitiveHit(text);
    if (word) { recordViolation(user, null, text, word); return fail(res, 422, '这条评论里有敏感词'); }
    const file = path.join(DATA_DIR, 'feed.json');
    const f = readJson(file, { items: [], posts: [] });
    const list = (f.posts || []).concat(f.items || []);
    const it = list.find((x) => x.id === id);
    if (!it) return fail(res, 404, '这条视频不在了');
    it.comments = Array.isArray(it.comments) ? it.comments : [];
    it.comments.push({ id: uid('fc'), userId: user.id, name: user.nickname || user.username, text: text, at: now() });
    if (it.comments.length > 200) it.comments = it.comments.slice(-200);
    writeJson(file, f);
    ok(res, { comments: it.comments.length + (Number(it.baseComments) || 0), text: text });
    return;
  }

  /* 用户自己发视频：先把视频/封面传到 /api/upload，再把地址发到这里 */
  if (parts[0] === 'feed' && parts[1] === 'publish' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    /* 违规账号（或风控分偏高）：视频号也不让发 */
    const fdWhy = mediaBlockedReason(user);
    if (fdWhy) return fail(res, 403, fdWhy);
    const body = await readBody(req);
    let video = str(body.video, 300);
    let cover = str(body.cover, 300);
    const desc = str(body.desc, 120) || '分享一条视频';
    const music = str(body.music, 60);
    if (!video || video.indexOf('/uploads/') !== 0) return fail(res, 422, '视频还没传上来');
    /* 压成「手机上刷得动」的规格：最长边 720、约 1.2Mbps、30fps、GOP 2 秒、
       H.264 High、AAC 96k、faststart（moov 放最前面，播放器不用整包下完才能出画面）。
       以前这段是 spawnSync + 直接读上传目录 —— 上传目录是密文，ffmpeg 根本读不了，
       等于从来没生效；而且 spawnSync 会把整个服务卡住几十秒（所有人一起转圈）。
       现在：先解到临时明文文件再转，异步跑（不占事件循环），顺手补一张封面。 */
    const srcName = path.basename(video);
    /* ⚡ 转码/抽封面/HLS 全部挪到后台（见 processFeedVideoPost）：
       2 核机器上一段视频转码要十几到几十秒，以前在这里同步等，用户上传完就一直转圈。
       现在立刻回包、原片先能看，后台转完再把这条的 video/cover 换成处理好的版本。 */
    const needCover = !cover;
    video = '/uploads/' + srcName;
    const word = sensitiveHit(desc);
    if (word) { recordViolation(user, null, desc, word); return fail(res, 422, '文案里有敏感词'); }
    const file = path.join(DATA_DIR, 'feed.json');
    const f = readJson(file, { items: [], posts: [] });
    f.posts = Array.isArray(f.posts) ? f.posts : [];
    const post = {
      id: uid('v'), authorId: user.id, video: video, cover: cover,
      desc: desc, music: music, createdAt: now(),
      likedBy: [], comments: [], baseLikes: 0, baseComments: 0, baseShares: 0
    };
    f.posts.unshift(post);
    if (f.posts.length > 200) f.posts = f.posts.slice(0, 200);
    writeJson(file, f);
    /* 后台处理这条新视频（转码 + 封面 + HLS），不挡这次请求 */
    setTimeout(() => { processFeedVideoPost(post.id, srcName, needCover); }, 50);
    /* 新视频进 feed 了：几秒后自动补一遍 HLS 分片（异步，不挡这次请求）。
       少了这一步，视频号就会退化成「整包下 mp4」——线上真出过：
       两条视频没有 hls 字段，客户端只能下 5.2MB / 3.6Mbps 的原片，看视频一直卡。 */
    scheduleHlsBuild();
    ok(res, { id: post.id, video: video });
    return;
  }

  /* 删自己发的那条 */
  /* 剪水印：把带水印的那一条边裁掉（ffmpeg 重编码），返回新地址。
     参数是比例：top/bottom/left/right = 0~0.4，比如底部水印就传 bottom:0.12。
     fill = 1 时裁完再放大回原尺寸（画面不缩小，只是看的内容变了）。 */
  if (parts[0] === 'feed' && parts[1] === 'trim' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const rel = str(body.url, 200);
    if (rel.indexOf('/uploads/') !== 0) return fail(res, 422, '视频地址不对');
    const name = path.basename(rel);
    const src = path.join(UPLOAD_DIR, name);
    if (!fs.existsSync(src)) return fail(res, 404, '视频不在了');
    const clamp = (v) => Math.max(0, Math.min(0.4, Number(v) || 0));
    const top = clamp(body.top), bottom = clamp(body.bottom);
    const left = clamp(body.left), right = clamp(body.right);
    if (top + bottom >= 0.8 || left + right >= 0.8) return fail(res, 422, '裁得太多了');
    if (!top && !bottom && !left && !right) return fail(res, 422, '没说要裁哪一边');
    const ff = process.env.FFMPEG_PATH || 'C:/Users/Administrator/ffmpeg/bin/ffmpeg.exe';
    const probeFf2 = ff.replace(/ffmpeg(\.exe)?$/i, 'ffprobe$1');
    /* 上传目录里是密文，ffmpeg 读不了 —— 先解到临时明文文件再剪（异步，不卡服务） */
    const tmpSrc = uploadTempPlain(name);
    const outTmp = tmpSrc + '.trim.mp4';
    const crop = 'crop=iw*(1-' + (left + right).toFixed(4) + '):ih*(1-' + (top + bottom).toFixed(4)
      + '):iw*' + left.toFixed(4) + ':ih*' + top.toFixed(4);
    /* 用 crop 的表达式算出裁剪后的真实尺寸，再决定要不要缩回原尺寸 */
    const probe = spawnSync(probeFf2,
      ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height',
        '-of', 'csv=p=0', tmpSrc], { encoding: 'utf8' });
    const dim = (probe.stdout || '').trim().split(',');
    const W = Number(dim[0]) || 720, H = Number(dim[1]) || 1280;
    const cw = Math.round(W * (1 - left - right));
    const ch = Math.round(H * (1 - top - bottom));
    const vf = (body.fill === false)
      ? crop
      : crop + ',scale=' + W + ':' + H;
    const args = ['-y', '-loglevel', 'error', '-i', tmpSrc, '-vf', vf,
                  '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '26', '-preset', 'veryfast'];
    /* 有音轨就保留 */
    const hasAudio = spawnSync(probeFf2,
      ['-v', 'error', '-select_streams', 'a', '-show_entries', 'stream=codec_type',
        '-of', 'csv=p=0', tmpSrc], { encoding: 'utf8' }).stdout.indexOf('audio') >= 0;
    if (hasAudio) args.push('-c:a', 'aac', '-b:a', '96k');
    args.push('-movflags', '+faststart', outTmp);
    const r = await runFfAsync(ff, args, 180000);
    if (!r.ok || !fs.existsSync(outTmp)) {
      callTrace('剪水印失败：' + String(r.err || '').slice(0, 200));
      try { fs.unlinkSync(tmpSrc); } catch (err) { }
      return fail(res, 500, '剪的时候出错了，换个视频试试');
    }
    const outName = saveUploadPlain(fs.readFileSync(outTmp), '.mp4');
    try { fs.unlinkSync(outTmp); } catch (err) { }
    try { fs.unlinkSync(tmpSrc); } catch (err) { }
    callTrace('剪水印 ' + name + ' → ' + outName + ' 裁掉 ' + JSON.stringify({ top, bottom, left, right }) + ' 新尺寸 ' + cw + 'x' + ch);
    ok(res, { url: '/uploads/' + outName, width: cw, height: ch });
    return;
  }

  if (parts[0] === 'feed' && parts.length === 2 && method === 'DELETE') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const file = path.join(DATA_DIR, 'feed.json');
    const f = readJson(file, { items: [], posts: [] });
    const before = (f.posts || []).length;
    f.posts = (f.posts || []).filter((x) => !(x.id === str(parts[1], 40) && x.authorId === user.id));
    writeJson(file, f);
    ok(res, { removed: before - f.posts.length });
    return;
  }

  /* 音乐：我正在听什么（好友的「朋友推荐」那一栏看这个） */
  if (parts[0] === 'music' && parts[1] === 'now' && method === 'POST') {
    const b = await readBody(req);
    const t = {
      id: str(b.id, 60),
      title: str(b.title, 80),
      artist: str(b.artist, 80),
      cover: str(b.cover, 400),
      url: str(b.url, 400)
    };
    if (!t.title) return fail(res, 422, '缺少歌名');
    const j = readMusicNow();
    j.users[user.id] = Object.assign({}, t, { at: Date.now() });
    saveMusicNow(j);
    ok(res, { at: j.users[user.id].at });
    return;
  }

  /* 我好友最近在听的（2 小时内的才算"在听"；机器人不进） */
  if (parts[0] === 'music' && parts[1] === 'friends' && method === 'GET') {
    const j = readMusicNow();
    const now = Date.now();
    const rows = [];
    friendIds(user.id).forEach((id) => {
      const it = j.users[id];
      if (!it || !it.title) return;
      if (now - Number(it.at || 0) > 2 * 3600 * 1000) return;
      const u = findUser(id);
      if (!u || u.bot) return;
      rows.push({
        id: id,
        name: displayNameFor(user.id, u) || u.nickname || u.username || '好友',
        avatar: u.avatar || '',
        trackId: it.id || '',
        title: it.title,
        artist: it.artist || '',
        cover: it.cover || '',
        url: it.url || '',
        at: Number(it.at) || 0
      });
    });
    rows.sort((a, b) => (b.at - a.at) || String(a.name).localeCompare(String(b.name)));
    ok(res, { list: rows.slice(0, 50), mine: j.users[user.id] || null });
    return;
  }

  /* 给好友的状态点个赞 / 取消（「朋友的状态」那一页） */
  if (parts[0] === 'status' && parts[1] === 'like' && method === 'POST') {
    const b = await readBody(req);
    const id = str(b.id, 60);
    const target = findUser(id);
    if (!target) return fail(res, 404, '找不到这个人');
    if (id === user.id) return fail(res, 422, '不能给自己的状态点赞');
    if (!Array.isArray(target.moodLikes)) target.moodLikes = [];
    const at = target.moodLikes.indexOf(user.id);
    if (at >= 0) target.moodLikes.splice(at, 1);
    else {
      target.moodLikes.push(user.id);
      /* 顺手给对方发一条实时事件：他那边能马上看到小红点/点赞数变了 */
      sendTo(id, { type: 'statusLike', userId: user.id, name: displayNameFor(id, user) || '' });
    }
    saveUsers();
    ok(res, { liked: at < 0, count: target.moodLikes.length });
    return;
  }

  /* 给这首歌点个赞 / 取消（播放器下面那颗心） */
  if (parts[0] === 'music' && parts[1] === 'like' && method === 'POST') {
    const b = await readBody(req);
    const id = str(b.id, 60);
    const dbm = readMusicDb();
    const t = dbm.tracks.filter((x) => x.id === id)[0];
    if (!t) return fail(res, 404, '找不到这首歌');
    if (!Array.isArray(t.likes)) t.likes = [];
    const at = t.likes.indexOf(user.id);
    if (at >= 0) t.likes.splice(at, 1);
    else t.likes.push(user.id);
    saveMusicDb(dbm);
    ok(res, { liked: at < 0, count: t.likes.length });
    return;
  }

  /* 转发一次（把音乐卡片发给好友时调一下）：只用来显示"被转了 N 次" */
  if (parts[0] === 'music' && parts[1] === 'share' && method === 'POST') {
    const b = await readBody(req);
    const id = str(b.id, 60);
    const dbm = readMusicDb();
    const t = dbm.tracks.filter((x) => x.id === id)[0];
    if (!t) return fail(res, 404, '找不到这首歌');
    t.shares = (Number(t.shares) || 0) + 1;
    saveMusicDb(dbm);
    ok(res, { count: t.shares });
    return;
  }

  /* ---------------- 棋牌大厅：桌子 ---------------- */
  if (parts[0] === 'games' && parts[1] === 'tables') {
    const sub = parts[2] || '';

    /* 大厅：现在摆着哪些桌子 */
    if (sub === '' && method === 'GET') {
      const want = str(query.get('game'), 20) || 'g09';
      const j = readTables();
      const list = j.tables.filter((t) => (t.game || 'g09') === want)
        .sort((a, b) => (b.at || 0) - (a.at || 0)).slice(0, 30)
        .map((t) => tablePublic(t, user.id));
      ok(res, { tables: list });
      return;
    }

    /* 自己开一桌 */
    if (sub === 'create' && method === 'POST') {
      const b = await readBody(req);
      const game = str(b.game, 20) || 'g09';
      const j = readTables();
      const seat = {
        id: user.id,
        name: displayNameFor(user.id, user) || user.nickname || '我',
        avatar: user.avatar || '', at: Date.now()
      };
      const t = {
        code: newTableCode(), game: game, host: user.id, started: false,
        seats: [seat, null, null, null], moves: [], seq: 0, at: Date.now()
      };
      j.tables.push(t);
      saveTables(j);
      ok(res, { table: tablePublic(t, user.id), seat: 0 });
      return;
    }

    /* 坐下（自动找最靠前的空位） */
    if (sub === 'sit' && method === 'POST') {
      const b = await readBody(req);
      const code = str(b.code, 10);
      const j = readTables();
      const t = j.tables.filter((x) => x.code === code)[0];
      if (!t) return fail(res, 404, '这张桌子没了（可能散场了）');
      if (!Array.isArray(t.seats)) t.seats = [null, null, null, null];
      let mine = t.seats.findIndex((x) => x && x.id === user.id);
      if (mine < 0) {
        mine = t.seats.findIndex((x) => !x);
        if (mine < 0) return fail(res, 409, '这桌坐满了，换一桌吧');
        t.seats[mine] = {
          id: user.id, name: displayNameFor(user.id, user) || user.nickname || '玩家',
          avatar: user.avatar || '', at: Date.now()
        };
      }
      if (!t.host) t.host = user.id;
      t.at = Date.now();
      const full = t.seats.filter(Boolean).length >= 4;
      if (full && !t.started) { t.started = true; t.seq = 0; t.moves = []; }
      saveTables(j);
      /* 通知同桌的人刷新 */
      t.seats.filter(Boolean).forEach((x) => {
        if (x.id !== user.id) sendTo(x.id, { type: 'gameTable', code: code });
      });
      ok(res, { table: tablePublic(t, user.id), seat: mine, started: t.started });
      return;
    }

    /* 开始（人没满也能先开，剩下的位由 AI 顶着） */
    if (sub === 'start' && method === 'POST') {
      const b = await readBody(req);
      const code = str(b.code, 10);
      const j = readTables();
      const t = j.tables.filter((x) => x.code === code)[0];
      if (!t) return fail(res, 404, '这张桌子没了');
      t.started = true;
      t.seq = 0;
      t.moves = [];
      t.at = Date.now();
      saveTables(j);
      (t.seats || []).filter(Boolean).forEach((x) => {
        if (x.id !== user.id) sendTo(x.id, { type: 'gameTable', code: code, started: true });
      });
      ok(res, { table: tablePublic(t, user.id) });
      return;
    }

    /* 离开 */
    if (sub === 'leave' && method === 'POST') {
      const b = await readBody(req);
      const code = str(b.code, 10);
      const j = readTables();
      const t = j.tables.filter((x) => x.code === code)[0];
      if (t) {
        t.seats = (t.seats || []).map((x) => (x && x.id === user.id) ? null : x);
        t.at = Date.now();
        if (!t.seats.filter(Boolean).length) j.tables = j.tables.filter((x) => x.code !== code);
        saveTables(j);
      }
      ok(res, { left: true });
      return;
    }

    /* 走一步：记下来，同桌的人轮询就能拿到 */
    if (sub === 'move' && method === 'POST') {
      const b = await readBody(req);
      const code = str(b.code, 10);
      const j = readTables();
      const t = j.tables.filter((x) => x.code === code)[0];
      if (!t) return fail(res, 404, '这张桌子没了');
      const seat = (t.seats || []).findIndex((x) => x && x.id === user.id);
      if (seat < 0) return fail(res, 403, '你没坐在这张桌子上');
      t.seq = (Number(t.seq) || 0) + 1;
      t.moves = (t.moves || []).concat([{ n: t.seq, seat: seat, move: b.move }]).slice(-500);
      t.at = Date.now();
      saveTables(j);
      ok(res, { n: t.seq });
      return;
    }

    /* 拉别人走的步 */
    if (sub === 'moves' && method === 'GET') {
      const code = str(query.get('code'), 10);
      const since = Number(query.get('since')) || 0;
      const j = readTables();
      const t = j.tables.filter((x) => x.code === code)[0];
      if (!t) return fail(res, 404, '这张桌子没了');
      const list = (t.moves || []).filter((m) => m.n > since);
      ok(res, { n: Number(t.seq) || 0, moves: list, started: !!t.started, table: tablePublic(t, user.id) });
      return;
    }
  }

  /* ============ App 里的「管理」（只有 ops = true 的用户能用） ============ */

  /* 拿管理页要的数据：曲库 + 小游戏/小程序清单 */
  if (parts[0] === 'manage' && parts.length === 1 && method === 'GET') {
    const mu = currentUser(req);
    if (!mu) return fail(res, 401, '请先登录');
    if (!mu.ops) return fail(res, 403, '你没有管理权限');
    ok(res, {
      music: readMusicDb().tracks,
      apps: miniAppList(null),
      games: miniAppList('game')
    });
    return;
  }

  /* 上新音乐（音频先用 /api/upload 传，再把地址发过来） */
  if (parts[0] === 'manage' && parts[1] === 'music' && parts.length === 2 && method === 'POST') {
    const mu = currentUser(req);
    if (!mu) return fail(res, 401, '请先登录');
    if (!mu.ops) return fail(res, 403, '你没有管理权限');
    const b = await readBody(req);
    const title = str(b.title, 60).replace(/\s+/g, ' ').trim();
    const url = str(b.url, 400).trim();
    if (!title) return fail(res, 422, '歌名不能为空');
    if (!/^(\/uploads\/|https?:\/\/)/.test(url)) return fail(res, 422, '先上传音频文件');
    /* iOS 只认 mp3 / m4a / wav / aac：别的格式（flac、ape、wma、下载来的怪后缀）
       在这里先用 ffmpeg 转成 mp3 再入库，不然 App 里点了没声音。 */
    let finalUrl = url;
    if (url.indexOf('/uploads/') === 0) {
      const base = path.basename(url);
      const ext = path.extname(base).toLowerCase();
      if (['.mp3', '.m4a', '.mp4', '.wav', '.aac'].indexOf(ext) < 0) {
        const conv = transcodeAudioToMp3(base);
        if (!conv) return fail(res, 422, '这个音频转不成 mp3（可能是加密格式或文件损坏）—— 换成 mp3 / m4a / flac 再传一次');
        finalUrl = conv;
      }
    }
    const dbm = readMusicDb();
    const id = str(b.id, 60);
    const old = id ? dbm.tracks.filter((t) => t.id === id)[0] : null;
    if (old) {
      old.title = title;
      old.artist = str(b.artist, 60).trim();
      if (/^(\/uploads\/|https?:\/\/)/.test(str(b.cover, 400).trim())) old.cover = str(b.cover, 400).trim();
      old.url = finalUrl;
    } else {
      dbm.tracks.unshift({
        id: uid('mus'),
        title: title,
        artist: str(b.artist, 60).trim(),
        cover: /^(\/uploads\/|https?:\/\/)/.test(str(b.cover, 400).trim()) ? str(b.cover, 400).trim() : '',
        url: finalUrl,
        lyrics: str(b.lyrics, 20000),
        at: Date.now()
      });
    }
    saveMusicDb(dbm);
    ok(res, { tracks: dbm.tracks.length, id: old ? old.id : dbm.tracks[0].id });
    return;
  }

  /* App 管理页里的「系统通知」开关（同一个配置文件） */
  if (parts[0] === 'manage' && parts[1] === 'sysnotice' && method === 'GET') {
    const mu = currentUser(req);
    if (!mu) return fail(res, 401, '请先登录');
    if (!mu.ops) return fail(res, 403, '你没有管理权限');
    ok(res, readSysNoticeCfg());
    return;
  }
  if (parts[0] === 'manage' && parts[1] === 'sysnotice' && method === 'POST') {
    const mu2 = currentUser(req);
    if (!mu2) return fail(res, 401, '请先登录');
    if (!mu2.ops) return fail(res, 403, '你没有管理权限');
    const mb = await readBody(req);
    const cur = readSysNoticeCfg();
    if (mb.enabled !== undefined) cur.enabled = mb.enabled ? 1 : 0;
    if (mb.types && typeof mb.types === 'object') {
      Object.keys(cur.types).forEach((k) => { if (mb.types[k] !== undefined) cur.types[k] = mb.types[k] ? 1 : 0; });
    }
    saveSysNoticeCfg(cur);
    ok(res, cur);
    return;
  }

  /* 批量删除音乐（管理页多选以后点删除） */
  if (parts[0] === 'manage' && parts[1] === 'music' && parts[2] === 'remove' && method === 'POST') {
    const mu = currentUser(req);
    if (!mu) return fail(res, 401, '请先登录');
    if (!mu.ops) return fail(res, 403, '你没有管理权限');
    const b = await readBody(req);
    const ids = Array.isArray(b.ids) ? b.ids.map((x) => String(x).slice(0, 60)) : [];
    const one = str(b.id, 60);
    const kill = ids.length ? ids : (one ? [one] : []);
    if (!kill.length) return fail(res, 422, '没选要删的歌');
    const dbm = readMusicDb();
    const before = dbm.tracks.length;
    dbm.tracks = dbm.tracks.filter((t) => kill.indexOf(t.id || '') < 0);
    saveMusicDb(dbm);
    ok(res, { removed: before - dbm.tracks.length, tracks: dbm.tracks.length });
    return;
  }

  /* 改小程序/小游戏：名字、说明、图标（emoji）、入口地址 */
  if (parts[0] === 'manage' && parts[1] === 'miniapp' && method === 'POST') {
    const mu = currentUser(req);
    if (!mu) return fail(res, 401, '请先登录');
    if (!mu.ops) return fail(res, 403, '你没有管理权限');
    const b = await readBody(req);
    const id = str(b.id, 60);
    const cfg = readMiniApps();
    const it = (cfg.items || []).filter((x) => (x.id || '') === id)[0];
    if (!it) return fail(res, 404, '找不到这个小程序');
    if (b.name !== undefined) it.name = str(b.name, 20) || it.name;
    if (b.desc !== undefined) it.desc = str(b.desc, 40);
    if (b.icon !== undefined) it.icon = str(b.icon, 8);
    if (b.group !== undefined) it.group = str(b.group, 16);
    if (b.action !== undefined) it.action = str(b.action, 6);
    if (b.url !== undefined) {
      const u = str(b.url, 400);
      if (u && !/^(\/|https?:\/\/)/.test(u)) return fail(res, 422, '入口地址要是 / 开头的路径或 http(s) 网址');
      if (u) it.url = u;
    }
    if (b.cover !== undefined) {
      const c = str(b.cover, 400).trim();
      if (c && !/^(\/uploads\/|https?:\/\/)/.test(c)) return fail(res, 422, '图标图片先上传再设置');
      it.cover = c;
    }
    saveMiniApps(cfg);
    ok(res, { id: id, item: it });
    return;
  }

  /* 换图标：音乐封面 或 小游戏图标（都是换一张图） */
  if (parts[0] === 'manage' && parts[1] === 'icon' && method === 'POST') {
    const mu = currentUser(req);
    if (!mu) return fail(res, 401, '请先登录');
    if (!mu.ops) return fail(res, 403, '你没有管理权限');
    const b = await readBody(req);
    const kind = str(b.kind, 20);
    const id = str(b.id, 60);
    const cover = str(b.cover, 400).trim();
    if (!/^(\/uploads\/|https?:\/\/)/.test(cover)) return fail(res, 422, '先上传图片');
    if (kind === 'music') {
      const dbm = readMusicDb();
      const t = dbm.tracks.filter((x) => x.id === id)[0];
      if (!t) return fail(res, 404, '找不到这首歌');
      t.cover = cover;
      saveMusicDb(dbm);
      ok(res, { id: id, cover: cover });
      return;
    }
    if (kind === 'miniapp') {
      const cfg = readMiniApps();
      const it = (cfg.items || []).filter((x) => (x.id || '') === id)[0];
      if (!it) return fail(res, 404, '找不到这个小游戏');
      it.cover = cover;
      saveMiniApps(cfg);
      ok(res, { id: id, cover: cover });
      return;
    }
    return fail(res, 422, 'kind 只能是 music 或 miniapp');
  }

  /* 官方号（名字 / 头像）：GET 拿清单，POST 改一个 —— 都属于「管理」，只有 ops 能用 */
  if (parts[0] === 'manage' && parts[1] === 'official' && parts.length === 2 && method === 'GET') {
    const mu = currentUser(req);
    if (!mu) return fail(res, 401, '请先登录');
    if (!mu.ops) return fail(res, 403, '你没有管理权限');
    ok(res, { items: officialList() });
    return;
  }
  if (parts[0] === 'manage' && parts[1] === 'official' && parts.length === 2 && method === 'POST') {
    const mu2 = currentUser(req);
    if (!mu2) return fail(res, 401, '请先登录');
    if (!mu2.ops) return fail(res, 403, '你没有管理权限');
    const mb = await readBody(req);
    const k = str(mb.key, 40).trim();
    if (!k) return fail(res, 422, '缺少 key');
    if (OFFICIAL_KEYS.indexOf(k) < 0) return fail(res, 422, '这个号不能改');
    const cfg = readOfficial();
    const cur = (cfg[k] && typeof cfg[k] === 'object') ? cfg[k] : {};
    if (mb.name !== undefined) {
      const nm = str(mb.name, 20).trim();
      if (!nm) return fail(res, 422, '名字不能为空');
      cur.name = nm;
    }
    if (mb.avatar !== undefined) {
      const av = str(mb.avatar, 400).trim();
      if (av && !/^(\/uploads\/|https?:\/\/)/.test(av)) return fail(res, 422, '头像先上传再设置');
      cur.avatar = av;
    }
    cfg[k] = cur;
    saveOfficial(cfg);
    applyOfficial(k);
    ok(res, { items: officialList() });
    return;
  }

  /* 小游戏：报分（App 的运行时在小游戏里自动调，游戏自己不用改） */
  if (parts[0] === 'games' && parts[1] === 'score' && method === 'POST') {
    const mu = currentUser(req);
    if (!mu) return fail(res, 401, '请先登录');
    const b = await readBody(req);
    const game = str(b.game, 40).replace(/[^A-Za-z0-9_.-]/g, '');
    const score = Math.max(0, Math.floor(Number(b.score) || 0));
    if (!game) return fail(res, 422, '缺少游戏标识');
    const dbg = readGameScores();
    const g = dbg.scores[game] || (dbg.scores[game] = {});
    const old = Number(g[mu.id]) || 0;
    if (score > old) { g[mu.id] = score; saveGameScores(dbg); }
    ok(res, { game: game, best: Math.max(old, score), improved: score > old });
    return;
  }

  /* 小游戏：好友排名（我 + 我的好友，按最高分排） */
  if (parts[0] === 'games' && parts[1] === 'rank' && method === 'GET') {
    const mu = currentUser(req);
    if (!mu) return fail(res, 401, '请先登录');
    const game = str(query.get('game'), 40).replace(/[^A-Za-z0-9_.-]/g, '');
    const dbg = readGameScores();
    const g = dbg.scores[game] || {};
    const ids = [mu.id].concat(friendIds(mu.id));
    const rows = [];
    ids.forEach((id) => {
      const u = findUser(id);
      if (!u || u.bot) return;                 // 机器人不进榜
      rows.push({
        id: id,
        name: displayNameFor(mu.id, u) || u.nickname || u.username || '好友',
        avatar: u.avatar || '',
        score: Number(g[id]) || 0,
        me: id === mu.id
      });
    });
    rows.sort((a, b) => (b.score - a.score) || String(a.name).localeCompare(String(b.name)));
    rows.forEach((r, i) => { r.rank = i + 1; });
    const mine = rows.filter((r) => r.me)[0] || { rank: rows.length, score: 0 };
    ok(res, { game: game, list: rows.slice(0, 60), total: rows.length,
              myRank: mine.rank || 0, myScore: mine.score || 0 });
    return;
  }

  if (parts[0] === 'games' && method === 'GET') {
    const cfg = readJson(path.join(DATA_DIR, 'games.json'), { items: [] });
    ok(res, { items: (cfg.items || []).filter((x) => x.enabled !== false) });
    return;
  }

  if (parts[0] === 'shake' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const lat = Number(body.lat);
    const lng = Number(body.lng);
    const me = (isFinite(lat) && isFinite(lng)) ? { lat: lat, lng: lng } : null;
    const map = pruneShakes();
    const mine = map[user.id] || { at: 0 };
    const seen = Array.isArray(mine.seen) ? mine.seen : [];
    const nowTs = Date.now();
    /* 同时在摇的人：30 秒内摇过、不是我、没被我摇到过 */
    const pool = Object.keys(map).filter((id) => id !== user.id)
      .filter((id) => map[id].at > nowTs - SHAKE_TTL_MS)
      .filter((id) => !seen.some((s) => s.id === id && nowTs - s.at < SHAKE_AGAIN_MS))
      .map((id) => {
        const u = findUser(id);
        const rec = map[id];
        let km = null;
        if (me && isFinite(rec.lat) && isFinite(rec.lng)) {
          km = nearbyKm(me, { lat: rec.lat, lng: rec.lng });
        } else if (map[user.id] && isFinite(map[user.id].lat)) {
          km = nearbyKm({ lat: map[user.id].lat, lng: map[user.id].lng }, { lat: rec.lat, lng: rec.lng });
        }
        return { u: u, km: km, at: rec.at };
      })
      .filter((x) => x.u && !x.u.banned && !x.u.bot);
    /* 近的先摇到；都没定位就随机 */
    pool.sort((a, b) => {
      const ka = a.km == null ? 1e9 : a.km;
      const kb = b.km == null ? 1e9 : b.km;
      if (ka === kb) return Math.random() - 0.5;
      return ka - kb;
    });
    const hit = pool[0] || null;
    const mySeen = seen.filter((s) => nowTs - s.at < SHAKE_AGAIN_MS);
    if (hit) mySeen.push({ id: hit.u.id, at: nowTs });
    map[user.id] = {
      at: nowTs,
      lat: isFinite(lat) ? lat : (mine.lat || null),
      lng: isFinite(lng) ? lng : (mine.lng || null),
      seen: mySeen.slice(-40)
    };
    saveShakes();
    if (!hit) {
      return ok(res, { matched: null, shaking: Object.keys(map).length });
    }
    const u = hit.u;
    ok(res, {
      matched: {
        id: u.id,
        nickname: u.nickname || u.username || '某人',
        avatar: u.avatar || '',
        gender: u.gender || '',
        region: u.region || '',
        bio: u.bio || '',
        moodText: u.moodText || '',
        online: connections.has(u.id),
        friend: friendIds(user.id).includes(u.id),
        km: hit.km == null ? null : Math.round(hit.km * 10) / 10
      },
      shaking: Object.keys(map).length
    });
    return;
  }

  if (parts[0] === 'nearby' && parts[1] === 'hello' && method === 'POST') {
    const user = currentUser(req);
    if (!user) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const target = findUser(str(body.userId, 40));
    if (!target) return fail(res, 404, '这个人已经不在附近了');
    if (target.id === user.id) return fail(res, 422, '不能给自己打招呼');
    const text = str(body.text, 60) || '你好呀，我是在附近的人里看到你的';
    let chat = directChatBetween(user.id, target.id);
    if (!chat) {
      chat = createDirectChat(user.id, target.id);
      sendTo(target.id, { type: 'chat', action: 'created', chat: chatSummary(chat, target.id) });
    }
    const result = deliverMessage(user, chat.id, 'text', text, null);
    if (result && result.error) return fail(res, 422, result.error);
    ok(res, { chatId: chat.id, text: text });
    return;
  }

  if (parts[0] === 'measure' && method === 'POST') {
    const body = await readBody(req);
    const file = path.join(DATA_DIR, 'measure.json');
    let list = [];
    try { list = JSON.parse(fs.readFileSync(file, 'utf8')) || []; } catch (err) { list = []; }
    list.push(Object.assign({ at: now() }, body));
    if (list.length > 400) list = list.slice(-400);
    writeJson(file, list);
    ok(res, { saved: true });
    return;
  }

  // 聊天输入栏「＋」面板（手机版启动时就拉这份配置）
  if (parts[0] === 'plus-panel' && method === 'GET') {
    ok(res, { items: db.plusPanel, quick: db.quickBar, plus: db.plusButton });
    return;
  }

  /* 发现页的行：后台加/删/改，前端（网页版和 App）每次打开都拉一次。
     图标分两种：icon 写 UI 图标页里的 key（后台换过图标就用换过的），
     或者直接给一段 svg。两者都没有就留空，前端只显示文字。 */
  if (parts[0] === 'discover' && method === 'GET') {
    const defs = readJson(path.join(DATA_DIR, 'icon-defaults.json'), { items: [] }).items || [];
    const overrides = readJson(path.join(DATA_DIR, ICONS_FILE), {});
    const builtin = {};
    defs.forEach((d) => { builtin[d.key] = d.svg || ''; });
    const items = (db.discover || [])
      .filter((it) => it.enabled !== false)
      .map((it) => {
        let svg = it.svg || overrides[it.icon] || builtin[it.icon] || '';
        /* 和「我」页一套规矩：会动的图标（anim:xxx）只发给认识它的版本，
           老版本回落到它本来就认识的静态 SVG —— 不然会被画成一串文字。 */
        if (svg.indexOf('anim:') === 0) {
          const bm = String(req.headers['x-app-build'] || '').match(/B(\d+)/);
          const buildNo = bm ? Number(bm[1]) : 0;
          if (buildNo < 723) svg = builtin[it.icon] || svg;
        }
        return Object.assign({}, it, { svg: svg });
      });
    ok(res, { items, version: assetVersion() });
    return;
  }

  /* 我页的行：和发现页一套机制（后台加/删/改，前端每次进来拉一次） */
  if (parts[0] === 'me-page' && method === 'GET') {
    const defs = readJson(path.join(DATA_DIR, 'icon-defaults.json'), { items: [] }).items || [];
    const overrides = readJson(path.join(DATA_DIR, ICONS_FILE), {});
    const builtin = {};
    defs.forEach((d) => { builtin[d.key] = d.svg || ''; });
    /* 会动的图标（服务端写 anim:xxx）只发给 B723 及以后的版本：
       老版本不认识这个字段，会把它当文字画出来 —— 所以按版本回落成静态 PNG。 */
    const ANIM_MIN_BUILD = 832;
    const ANIM_FALLBACK = {
      service: '/uploads/micon-service.png',
      favorites: '/uploads/micon-favorites.png',
      moments: '/uploads/micon-moments.png',
      works: '/uploads/micon-works.png',
      stickers: '/uploads/micon-stickers.png',
      settings: '/uploads/micon-settings.png',
      /* 我页照微信补的两行：老版本上没有对应的静态图，先借用主题接近的那两张 */
      shop: '/uploads/micon-works.png',
      plugins: '/uploads/micon-settings.png'
    };
    const meBuildNo = (() => {
      const m = String(req.headers['x-app-build'] || '').match(/B(\d+)/);
      return m ? Number(m[1]) : 0;
    })();
    const items = (db.mePage || [])
      .filter((it) => it.enabled !== false)
      .map((it) => {
        let svg = it.svg || overrides[it.icon] || builtin[it.icon] || '';
        if (svg.indexOf('anim:') === 0) {
          const kind = svg.slice(5);
          if (meBuildNo < ANIM_MIN_BUILD) svg = ANIM_FALLBACK[kind] || svg;
        }
        return Object.assign({}, it, { svg: svg });
      });
    ok(res, { items, version: assetVersion() });
    return;
  }



  /* 聊天壁纸：App「聊天背景」页的 6 张基础壁纸 + 默认壁纸（全部后台配，不用出新包） */
  if (parts[0] === 'chat-bg' && method === 'GET') {
    const cfg = db.chatBg || normalizeChatBg(null);
    ok(res, { default: cfg.default, presets: cfg.presets,
              version: String(cfg.version) + '-' + String(assetVersion()) });
    return;
  }
  /* 服务页（我 → 服务）：整页都由后台配（绿卡 + 分类 + 格子），
     前端每次进来拉一次，后台改完切回前台就生效。 */
  if (parts[0] === 'service' && method === 'GET') {
    const defs = readJson(path.join(DATA_DIR, 'icon-defaults.json'), { items: [] }).items || [];
    const overrides = readJson(path.join(DATA_DIR, ICONS_FILE), {});
    const builtin = {};
    defs.forEach((d) => { builtin[d.key] = d.svg || ''; });
    const svgOf = (icon, own) => own || overrides[icon] || builtin[icon] || '';
    const cfg = db.service || normalizeService(null);
    const card = cfg.card || {};
    const half = (h) => Object.assign({}, h, { svg: svgOf(h && h.icon, h && h.svg) });
    const groups = (cfg.groups || [])
      .filter((g) => g.enabled !== false)
      .map((g) => Object.assign({}, g, {
        items: (g.items || [])
          .filter((it) => it.enabled !== false)
          .map((it) => Object.assign({}, it, { svg: svgOf(it.icon, it.svg) }))
      }))
      .filter((g) => g.items.length);
    ok(res, {
      title: cfg.title || '服务',
      card: { enabled: card.enabled !== false, bg: card.bg || '#2AAE67', left: half(card.left), right: half(card.right) },
      bottom: cfg.bottom || normalizeService(null).bottom,
      style: cfg.style || normalizeService(null).style,
      groups: groups,
      version: assetVersion()
    });
    return;
  }

  /* 钱包页（我 → 服务 → 钱包）：整页也由后台配。
     零钱那一行的数值支持「跟余额」：valueKind = balance 就现算这个人的零钱余额。 */
  /* 只匹配 /api/wallet 本身；子路径（banks / withdraws…）由后面各自的接口处理 */
  if (parts[0] === 'wallet' && parts.length === 1 && method === 'GET') {
    const defs = readJson(path.join(DATA_DIR, 'icon-defaults.json'), { items: [] }).items || [];
    const overrides = readJson(path.join(DATA_DIR, ICONS_FILE), {});
    const builtin = {};
    defs.forEach((d) => { builtin[d.key] = d.svg || ''; });
    const svgOf = (icon, own) => own || overrides[icon] || builtin[icon] || '';
    const me = currentUser(req);
    /* 强制实名：没实名进不了钱包页（和微信一样）。
       App 收到 needRealName 会弹实名认证 + 显示「请先实名」的页面。 */
    if (blockedByRealName(res, me)) return;
    const cfg = db.wallet || normalizeWallet(null);
    /* 后台把「点一下能看」也关了的话，连数值都不下发（只给 ¥****），前端想看也没有 */
    const hardMask = !!(cfg.style && cfg.style.maskAmount !== false && cfg.style.maskReveal === false);
    const maskMoney = (s) => {
      const t = String(s == null ? '' : s);
      if (!t) return t;
      return t.indexOf('¥') >= 0 ? '¥****' : t.replace(/[0-9]/g, '*');
    };
    const pick = (it) => {
      let value = it.valueKind === 'balance'
        ? ('¥' + (Number(me && me.balance) || 0).toFixed(2))
        : (it.value || '');
      if (hardMask && value && it.mask !== false) value = maskMoney(value);
      return Object.assign({}, it, { value: value, svg: svgOf(it.icon, it.svg) });
    };
    const groups = (cfg.groups || [])
      .filter((g) => g.enabled !== false)
      .map((g) => Object.assign({}, g, {
        items: (g.items || []).filter((it) => it.enabled !== false).map(pick)
      }))
      .filter((g) => g.items.length);
    ok(res, {
      title: cfg.title || '钱包',
      right: cfg.right,
      groups: groups,
      footer: (cfg.footer || []).filter((f) => f.enabled !== false),
      style: cfg.style || normalizeWallet(null).style,
      balance: Number(me && me.balance) || 0,
      version: assetVersion()
    });
    return;
  }

  /* 账单：这个人所有的转账（钱包页右上角「账单」用）。
     带上对方是谁（名字/头像）、进出方向、状态、时间，再给一份汇总和月份列表。 */
  if (parts[0] === 'bills' && method === 'GET') {
    const me = currentUser(req);
    if (blockedByRealName(res, me)) return;      // 账单属于钱包，同样要实名
    const limit = Math.min(200, Math.max(1, Number(query.get('limit')) || 100));
    const month = str(query.get('month'), 7);          // 形如 2026-09，不传就是全部
    let all = (db.transfers || [])
      .filter((t) => t && (t.fromId === me.id || t.toId === me.id))
      .map((t) => {
        const mine = t.fromId === me.id;
        const other = findUser(mine ? t.toId : t.fromId) || {};
        return {
          id: t.id,
          chatId: t.chatId || '',
          amount: Number(t.amount) || 0,
          note: t.note || '',
          method: t.method || 'balance',
          status: t.status || 'pending',
          createdAt: t.createdAt || '',
          expiresAt: t.expiresAt || 0,
          receivedAt: t.receivedAt || '',
          refundedAt: t.refundedAt || '',
          direction: mine ? 'out' : 'in',
          peerId: other.id || '',
          peerName: other.nickname || '好友',
          peerAvatar: other.avatar || ''
        };
      })
      .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());
    /* 零钱的充值 / 提现也一起进账单（微信的账单里这些都有） */
    const walletBills = readWalletOps().ops
      .filter((o) => o.userId === me.id)
      .map((o) => ({
        id: o.id,
        chatId: '',
        amount: Number(o.amount) || 0,
        note: o.kind === 'recharge' ? '充值' : '提现',
        method: 'balance',
        status: o.status === 'done' ? 'received' : (o.status === 'failed' ? 'refunded' : 'pending'),
        createdAt: o.createdAt || '',
        expiresAt: 0,
        receivedAt: o.doneAt || '',
        refundedAt: '',
        direction: o.kind === 'recharge' ? 'in' : 'out',
        peerId: '',
        peerName: o.bankText || '银行卡',
        peerAvatar: '',
        walletKind: o.kind,
        fee: Number(o.fee) || 0
      }));
    /* 红包也进账单：发出去的算支出、抢到的算收入、24 小时退回的算收入 */
    const rpBills = [];
    (db.redpackets || []).forEach((r) => {
      const mine = rpClaims(r).find((c) => c.userId === me.id) || null;
      const note = r.note || (r.type === 'lucky' ? '拼手气红包' : '红包');
      if (r.fromId === me.id) {
        /* 我发的红包：头像用我自己的（微信账单里这一条也是对方头像的位置放自己的） */
        rpBills.push({
          id: r.id + '-out', chatId: r.chatId, amount: Number(r.total) || 0,
          note: '发红包 · ' + note, method: 'balance', status: 'received',
          createdAt: r.createdAt, expiresAt: 0, receivedAt: r.createdAt, refundedAt: '',
          direction: 'out', peerId: '', peerName: note,
          peerAvatar: (me && me.avatar) || '',
          walletKind: 'redpacket'
        });
        if (Number(r.refundAmount) > 0 && r.refundedAt) {
          rpBills.push({
            id: r.id + '-back', chatId: r.chatId, amount: Number(r.refundAmount) || 0,
            note: '红包退回 · ' + note, method: 'balance', status: 'received',
            createdAt: r.refundedAt, expiresAt: 0, receivedAt: r.refundedAt, refundedAt: '',
            direction: 'in', peerId: '', peerName: note, peerAvatar: '',
            walletKind: 'redpacket'
          });
        }
      }
      if (mine) {
        const sender = findUser(r.fromId) || {};
        rpBills.push({
          id: r.id + '-in', chatId: r.chatId, amount: Number(mine.amount) || 0,
          note: '抢到红包 · ' + note, method: 'balance', status: 'received',
          createdAt: mine.at, expiresAt: 0, receivedAt: mine.at, refundedAt: '',
          direction: 'in', peerId: r.fromId, peerName: r.fromName || sender.nickname || '好友',
          peerAvatar: sender.avatar || '',      // 账单里要看到对方的头像
          walletKind: 'redpacket'
        });
      }
    });
    /* 开通会员花的钱也进账单（按里那条「开通会员」） */
    const memberBills = memberHistoryOf(me.id)
      .filter((h) => Number(h.price) > 0)
      .map((h) => {
        const t = tierOf(h.tier);
        return {
          id: 'mb-' + String(h.at || '') + '-' + String(h.tier || ''),
          chatId: '', amount: Math.abs(Number(h.price) || 0),
          note: '开通' + ((t && t.name) || '会员') + (h.months ? (' ' + h.months + ' 个月') : ''),
          method: 'balance', status: 'received',
          createdAt: h.at || '', expiresAt: 0, receivedAt: h.at || '', refundedAt: '',
          direction: 'out', peerId: '', peerName: '会员服务', peerAvatar: '',
          walletKind: 'member'
        };
      });
    if (walletBills.length || rpBills.length || memberBills.length) {
      all = all.concat(walletBills, rpBills, memberBills)
        .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());
    }
    const list = (month ? all.filter((x) => String(x.createdAt).slice(0, 7) === month) : all).slice(0, limit);
    const total = (dir, statuses) => Math.round(all
      .filter((x) => x.direction === dir && (!statuses || statuses.indexOf(x.status) >= 0))
      .reduce((a, x) => a + x.amount, 0) * 100) / 100;
    const months = [];
    all.forEach((x) => {
      const m = String(x.createdAt).slice(0, 7);
      if (/^\d{4}-\d{2}$/.test(m) && months.indexOf(m) < 0) months.push(m);
    });
    ok(res, {
      bills: list,
      months: months.slice(0, 36),
      summary: {
        out: total('out', ['pending', 'received']),
        in: total('in', ['received']),
        pendingOut: all.filter((x) => x.direction === 'out' && x.status === 'pending').length,
        pendingIn: all.filter((x) => x.direction === 'in' && x.status === 'pending').length,
        count: all.length
      },
      month: month || '',
      style: (db.billsPage || normalizeBillsPage(null)).style,
      faq: (db.billsPage || normalizeBillsPage(null)).faq,
      version: assetVersion()
    });
    return;
  }

  /* 零钱页（我 → 服务 → 钱包 → 零钱）：文案/按钮/链接都是后台配的，
     余额是这个人的真实零钱（冻结金额目前恒为 0，等有冻结逻辑再接）。 */
  if (parts[0] === 'balance-page' && method === 'GET') {
    const me = currentUser(req);
    /* 强制实名：没实名进不了零钱页（和微信一样）。
       App 收到 needRealName 会弹实名认证 + 显示「请先实名」的页面，不会再退回默认字号。 */
    if (blockedByRealName(res, me)) return;
    const cfg = db.balancePage || normalizeBalancePage(null);
    ok(res, Object.assign({}, cfg, {
      balance: Number(me && me.balance) || 0,
      frozen: 0,
      version: assetVersion()
    }));
    return;
  }

  /* 看一看（和微信一样两块）：①「朋友在看」= 视频号里朋友看过的；
     ② 兜底 = 朋友最近点赞过的朋友圈动态（视频号没内容时也有东西看）。
     内容源：data/feed.json（视频号）+ data/feed-views.json（谁看过哪条）+ moments.json */
  if (parts[0] === 'lookaround' && method === 'GET') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const nmx = (id) => { const u = findUser(String(id || '')); return u ? (u.nickname || u.username || '') : ''; };
    const friends = new Set(friendIds(me.id));
    const f = readJson(path.join(DATA_DIR, 'feed.json'), { items: [], posts: [] });
    const allVideos = (f.items || []).concat(f.posts || []).filter((v) => v && v.id);
    const views = readJson(path.join(DATA_DIR, 'feed-views.json'), {}) || {};
    const videos = allVideos.map((v) => {
      const watchers = Object.keys(views).filter((uid) => friends.has(uid) && ((views[uid] || {})[v.id] || {}).count > 0);
      const total = Object.keys(views).filter((uid) => ((views[uid] || {})[v.id] || {}).count > 0).length;
      return {
        id: v.id, title: v.title || v.caption || '', cover: v.cover || v.thumb || '', video: v.url || v.src || '',
        authorId: v.authorId || '', author: v.authorId ? nmx(v.authorId) : (v.author || ''),
        createdAt: v.createdAt || '', dur: Number(v.dur) || 0, likes: Number(v.likes) || 0,
        watched: total, friendsCount: watchers.length,
        friends: watchers.slice(0, 3).map((uid) => ({ id: uid, name: nmx(uid), avatar: (findUser(uid) || {}).avatar || '' }))
      };
    });
    const friendVideos = videos.filter((v) => v.friendsCount > 0)
      .sort((a, b) => b.friendsCount - a.friendsCount || String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, 30);
    const hotVideos = videos.slice()
      .sort((a, b) => (b.watched - a.watched) || (b.likes - a.likes) || String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, 30);
    const friendMoments = (db.moments || [])
      .filter((m) => m && m.authorId !== me.id && Array.isArray(m.likes) && m.likes.some((id) => friends.has(id)))
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, 20)
      .map((m) => ({
        id: m.id, authorId: m.authorId, author: nmx(m.authorId),
        content: String(m.content || '').slice(0, 80),
        images: (m.images || []).slice(0, 3),
        createdAt: m.createdAt, likeCount: (m.likes || []).length,
        whoLiked: (m.likes || []).filter((id) => friends.has(id)).slice(0, 3)
          .map((id) => ({ id, name: nmx(id), avatar: (findUser(id) || {}).avatar || '' }))
      }));
    /* 视频号被清空 / 没人点赞过时，用「大家都在看」和「朋友最近发的」兜底，
       保证这一页不会是一片空白（微信的看一看也总有内容）。 */
    const pick = (m) => ({
      id: m.id, authorId: m.authorId, author: nmx(m.authorId),
      content: String(m.content || '').slice(0, 80),
      images: (m.images || []).slice(0, 3),
      createdAt: m.createdAt, likeCount: (m.likes || []).length,
      commentCount: (m.comments || []).length
    });
    const visible = (db.moments || []).filter((m) => m && momentVisibleTo(m, me.id));
    const hotMoments = visible.slice()
      .sort((a, b) => ((b.likes || []).length + (b.comments || []).length) - ((a.likes || []).length + (a.comments || []).length)
        || String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, 20).map(pick);
    const friendRecent = visible.filter((m) => m.authorId !== me.id && friends.has(m.authorId))
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, 20).map(pick);
    ok(res, {
      videos: friendVideos, hot: hotVideos, moments: friendMoments,
      hotMoments: hotMoments, friendRecent: friendRecent
    });
    return;
  }

  /* 搜一搜：一次搜完 联系人 / 群聊 / 朋友圈 / 视频号 / 聊天记录（和微信那个搜索页一样分组给）。
     scope 可以是 people / groups / moments / videos / messages / all */
  if (parts[0] === 'search' && method === 'GET') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const nmx = (id) => { const u = findUser(String(id || '')); return u ? (u.nickname || u.username || '') : ''; };
    const q = String(query.get('q') || '').trim().slice(0, 40);
    const scope = String(query.get('scope') || 'all');
    if (!q) return ok(res, { people: [], groups: [], moments: [], videos: [], messages: [] });
    const lower = q.toLowerCase();
    const want = (k) => scope === 'all' || scope === k;
    const out = { people: [], groups: [], moments: [], videos: [], messages: [] };
    if (want('people')) {
      out.people = friendIds(me.id).map(findUser).filter(Boolean)
        .filter((u) => displayNameFor(me.id, u).toLowerCase().includes(lower)
          || String(u.username || '').toLowerCase().includes(lower))
        .slice(0, 20)
        .map((u) => ({ id: u.id, name: displayNameFor(me.id, u), username: u.username || '', avatar: u.avatar || '' }));
    }
    if (want('groups')) {
      out.groups = db.chats
        .filter((c) => c.type === 'group' && (c.memberIds || []).includes(me.id)
          && String(c.name || '').toLowerCase().includes(lower))
        .slice(0, 20)
        .map((c) => ({ id: c.id, name: c.name || '', avatar: c.avatar || '', members: (c.memberIds || []).length }));
    }
    if (want('moments')) {
      out.moments = (db.moments || [])
        .filter((m) => m && momentVisibleTo(m, me.id) && String(m.content || '').toLowerCase().includes(lower))
        .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
        .slice(0, 20)
        .map((m) => ({
          id: m.id, authorId: m.authorId, author: nmx(m.authorId),
          content: String(m.content || '').slice(0, 120),
          images: (m.images || []).slice(0, 3), createdAt: m.createdAt
        }));
    }
    if (want('videos')) {
      const f = readJson(path.join(DATA_DIR, 'feed.json'), { items: [], posts: [] });
      out.videos = (f.items || []).concat(f.posts || [])
        .filter((v) => v && (String(v.title || '') + String(v.caption || '')).toLowerCase().includes(lower))
        .slice(0, 20)
        .map((v) => ({ id: v.id, title: v.title || v.caption || '', cover: v.cover || '', authorId: v.authorId || '', author: v.authorId ? nmx(v.authorId) : '' }));
    }
    if (want('messages')) {
      const hits = [];
      for (const c of chatsOf(me.id)) {
        if (hits.length >= 30) break;
        const msgs = loadMessages(c.id);
        for (let i = msgs.length - 1; i >= 0 && hits.length < 30; i -= 1) {
          const m = msgs[i];
          if (!m || m.recalled) continue;
          if (!String(m.content || '').toLowerCase().includes(lower)) continue;
          const peerId = (c.memberIds || []).find((id) => id !== me.id) || '';
          hits.push({
            chatId: c.id, isGroup: c.type === 'group',
            chatTitle: c.type === 'group' ? (c.name || '群聊') : nmx(peerId),
            peerId, messageId: m.id, senderId: m.senderId, sender: nmx(m.senderId),
            text: String(m.content || '').slice(0, 120), at: m.createdAt
          });
        }
      }
      out.messages = hits.sort((a, b) => String(b.at).localeCompare(String(a.at))).slice(0, 30);
    }
    /* 临时调试：确认搜索内部到底扫了多少会话/消息（排查完就删） */
    out._dbg = {
      scope: scope, q: q,
      chats: chatsOf(me.id).length,
      scanned: chatsOf(me.id).reduce((n, c) => n + loadMessages(c.id).length, 0)
    };
    ok(res, out);
    return;
  }

  // 礼物列表（前台「礼物」面板用，只给启用的）
  if (parts[0] === 'gifts' && method === 'GET') {
    ok(res, { gifts: db.gifts.filter((g) => g.enabled) });
    return;
  }

  // 状态列表（手机端「我 → ＋ 状态」用，分类和状态都是后台配的）
  if (parts[0] === 'statuses' && parts.length === 1 && method === 'GET') {
    ok(res, { categories: db.statuses.filter((c) => c.enabled) });
    return;
  }

  // 表情包：本地表情包 + 第三方图源开关（手机端「我 → 表情」用）
  if (parts[0] === 'stickers' && parts.length === 1 && method === 'GET') {
    /* 这一段路由在「取当前用户」之前，所以自己取一次（没登录就是空的） */
    const me = currentUser(req);
    const mine = me ? myStickers(me.id) : { packs: [], singles: [], recent: [] };
    ok(res, {
      packs: db.stickers.packs.filter((p) => p.enabled),
      /* 「我的表情」：已添加的表情包（完整数据）+ 自己添加的单个表情 */
      mine: {
        packs: db.stickers.packs.filter((p) => p.enabled && mine.packs.includes(p.id)),
        singles: mine.singles,
        recent: mine.recent
      },
      thirdParty: {
        provider: db.stickers.thirdParty.provider,
        enabled: db.stickers.thirdParty.provider !== 'off'
          && (!!db.stickers.thirdParty.apiKey || !!db.stickers.thirdParty.urlTemplate),
        limit: db.stickers.thirdParty.limit
      }
    });
    return;
  }

  /* 表情：添加 / 移除（表情包或单个表情）—— 微信「我 → 表情」里那套 */
  if (parts[0] === 'stickers' && parts[1] === 'add' && method === 'POST') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const mine = myStickers(me.id);
    const packId = str(body.packId, 24);
    const single = str(body.sticker, 400);
    if (packId) {
      if (!db.stickers.packs.some((p) => p.id === packId && p.enabled)) return fail(res, 404, '没有这个表情包');
      if (!mine.packs.includes(packId)) mine.packs.push(packId);
    } else if (single) {
      if (!mine.singles.includes(single)) mine.singles.push(single);
    } else {
      return fail(res, 422, '要添加哪个表情？');
    }
    setMyStickers(me.id, mine);
    ok(res, { mine });
    return;
  }

  if (parts[0] === 'stickers' && parts[1] === 'remove' && method === 'POST') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const mine = myStickers(me.id);
    const packId = str(body.packId, 24);
    const single = str(body.sticker, 400);
    if (packId) mine.packs = mine.packs.filter((x) => x !== packId);
    if (single) {
      mine.singles = mine.singles.filter((x) => x !== single);
      mine.recent = mine.recent.filter((x) => x !== single);
    }
    setMyStickers(me.id, mine);
    ok(res, { mine });
    return;
  }

  /* 用过某个表情：记进「最近使用」（微信表情面板第一格就是最近使用） */
  if (parts[0] === 'stickers' && parts[1] === 'recent' && method === 'POST') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const single = str(body.sticker, 400);
    if (single) {
      const mine = myStickers(me.id);
      mine.recent = [single].concat(mine.recent.filter((x) => x !== single)).slice(0, 30);
      setMyStickers(me.id, mine);
    }
    ok(res, { ok: true });
    return;
  }

  /* ============================================================
     存储空间（微信「设置 → 通用 → 存储空间」）
     按会话统计聊天记录条数与占用，按类型统计图片/视频/文件/语音，
     还能清缓存（把没人引用的上传文件删掉，不会动别人还能看到的东西）。
     ============================================================ */
  if (parts[0] === 'storage' && method === 'GET') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const mine = chatsOf(me.id);
    let total = 0;
    const byKind = { image: 0, video: 0, file: 0, audio: 0 };
    const chats = mine.map((c) => {
      const msgs = loadMessages(c.id);
      let bytes = 0;
      msgs.forEach((m) => {
        const size = Buffer.byteLength(JSON.stringify(m), 'utf8');
        bytes += size;
        if (m.kind === 'image') byKind.image += size;
        else if (m.kind === 'file') {
          const isVideo = /\.(mp4|mov|m4v|avi|mkv|webm|3gp|flv|wmv)(\?|$)/i.test(String(m.content || ''));
          byKind[isVideo ? 'video' : 'file'] += size;
        } else if (m.kind === 'audio') byKind.audio += size;
      });
      total += bytes;
      return {
        chatId: c.id, title: chatSummary(c, me.id).title, avatar: c.avatar || '',
        messages: msgs.length, bytes
      };
    }).sort((a, b) => b.bytes - a.bytes);
    ok(res, {
      total, chats,
      kinds: byKind,
      /* 服务器上传目录的实际占用（全站的，给用户一个「缓存」参考值） */
      uploads: uploadDirSize()
    });
    return;
  }

  /* 清缓存：**只算不删**。
     2026-09-22 出过事故：服务器上的清理把还在用的图片/语音当成"没人引用"删掉了 91 个文件（207MB），
     所以普通用户这边只返回「能清多少」，真删只能管理员在后台点（而且只删 24 小时前、确认没人引用的）。 */
  if (parts[0] === 'storage' && parts[1] === 'clean' && method === 'POST') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    ok(res, { freed: 0, wouldFree: orphanUploadsSize(), note: '服务器上的文件不能由用户端删除' });
    return;
  }

  /* ============================================================
     共享实时位置（微信「＋ → 位置 → 共享实时位置」）
     一个会话里同时只有一个共享会话：谁进来都看得到彼此的位置，
     位置更新走长连接实时转发，「停止共享」大家一起结束。
     会话只放内存，2 小时自动过期（不做落盘，重启也没了 —— 微信也是临时会话）。
     ============================================================ */
  if (parts[0] === 'live' && parts[1] === 'start' && method === 'POST') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const chat = db.chats.find((c) => c.id === str(body.chatId, 40));
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(me.id)) return fail(res, 403, '你不在这个会话里');
    const exist = Array.from(liveLocations.values())
      .find((s) => s.chatId === chat.id && Date.now() - s.at < LIVE_LOCATION_TTL);
    const ses = exist || { id: uid('ll'), chatId: chat.id, fromId: me.id, at: Date.now(), positions: {} };
    ses.at = Date.now();
    const lat = Number(body.lat), lng = Number(body.lng);
    if (isFinite(lat) && isFinite(lng)) ses.positions[me.id] = { lat, lng, at: Date.now() };
    liveLocations.set(ses.id, ses);
    sendToChat(chat, {
      type: 'live-location', action: 'start', sessionId: ses.id, chatId: chat.id,
      fromId: me.id, fromName: me.nickname || me.username
    }, me.id);
    ok(res, { sessionId: ses.id, joined: !!exist });
    return;
  }

  /* 上报我的位置：每几秒一次，服务器转给同一会话里的其他人 */
  if (parts[0] === 'live' && parts[1] === 'pos' && method === 'POST') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const ses = liveLocations.get(str(body.sessionId, 40));
    if (!ses) return fail(res, 404, '共享已结束');
    const chat = db.chats.find((c) => c.id === ses.chatId);
    if (!chat || !chat.memberIds.includes(me.id)) return fail(res, 403, '你不在这个共享里');
    const lat = Number(body.lat), lng = Number(body.lng);
    if (!isFinite(lat) || !isFinite(lng)) return fail(res, 422, '坐标不对');
    ses.positions[me.id] = { lat, lng, at: Date.now() };
    ses.at = Date.now();
    sendToChat(chat, {
      type: 'live-location', action: 'pos', sessionId: ses.id, chatId: chat.id,
      userId: me.id, name: me.nickname || me.username, avatar: me.avatar || '',
      lat, lng
    }, me.id);
    ok(res, { ok: true });
    return;
  }

  /* 进页面先拉一次：现在这个共享里都有谁、都在哪 */
  if (parts[0] === 'live' && parts[2] === 'state' && method === 'GET') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const ses = liveLocations.get(str(parts[1], 40));
    if (!ses) return fail(res, 404, '共享已结束');
    const chat = db.chats.find((c) => c.id === ses.chatId);
    if (!chat || !chat.memberIds.includes(me.id)) return fail(res, 403, '你不在这个共享里');
    const list = Object.keys(ses.positions).map((id) => {
      const x = findUser(id);
      return {
        userId: id, name: (x && (x.nickname || x.username)) || '',
        avatar: (x && x.avatar) || '',
        lat: ses.positions[id].lat, lng: ses.positions[id].lng, at: ses.positions[id].at
      };
    });
    ok(res, { sessionId: ses.id, chatId: ses.chatId, fromId: ses.fromId, members: list });
    return;
  }

  /* 停止共享：整条会话一起结束 */
  if (parts[0] === 'live' && parts[1] === 'stop' && method === 'POST') {
    const me = currentUser(req);
    if (!me) return fail(res, 401, '请先登录');
    const body = await readBody(req);
    const ses = liveLocations.get(str(body.sessionId, 40));
    if (ses) {
      const chat = db.chats.find((c) => c.id === ses.chatId);
      liveLocations.delete(ses.id);
      if (chat) sendToChat(chat, { type: 'live-location', action: 'stop', sessionId: ses.id, chatId: chat.id });
    }
    ok(res, { stopped: true });
    return;
  }

  /* 服务器身份（看门狗用）：说明这个端口上跑的是哪一份数据目录。
     备用目录里如果也有一份 CHRIS 服务器抢着 5180，看门狗靠这个认得出是不是我们这份。 */
  if (parts[0] === 'which' && method === 'GET') {
    ok(res, { dir: DATA_DIR, pid: process.pid, up: Math.floor(process.uptime()) });
    return;
  }

  // 第三方表情搜索：服务端代跑请求（手机在内网，也能用官方 key 直连外部平台）
  if (parts[0] === 'stickers' && parts[1] === 'search' && method === 'GET') {
    const tp = db.stickers.thirdParty;
    const url = thirdPartyUrl(tp, str(query.get('q'), 30));
    if (!url) return ok(res, { items: [], provider: tp.provider, note: '第三方图源没开或没配 key' });
    try {
      const ctl = new AbortController();
      const timer = setTimeout(() => ctl.abort(), 8000);
      const r = await fetch(url, { signal: ctl.signal, headers: { 'Accept': 'application/json' } });
      clearTimeout(timer);
      const data = await r.json().catch(() => null);
      ok(res, { items: parseThirdParty(tp.provider, data), provider: tp.provider, status: r.status });
    } catch (err) {
      ok(res, { items: [], provider: tp.provider, error: '第三方请求失败：' + (err && err.message ? err.message : '未知错误') });
    }
    return;
  }

  if (parts[0] === 'register' && method === 'POST') {
    const body = await readBody(req);
    const username = str(body.username, 24);
    const nickRaw = str(body.nickname, 24);
    if (nickRaw) {
      const bad = checkNickname(nickRaw);
      if (bad) return fail(res, 422, bad);
    }
    const nickname = nickRaw || username;
    const password = String(body.password || '');
    if (!/^[A-Za-z0-9_]{3,24}$/.test(username)) return fail(res, 422, '用户名需为 3-24 位字母、数字或下划线');
    if (password.length < 6) return fail(res, 422, '密码至少 6 位');
    const phone = str(body.phone, 20);
    if (phone && !/^[0-9+\-\s]{5,20}$/.test(phone)) return fail(res, 422, '手机号格式不正确（也可以留空）');
    if (!checkCaptcha(body.captchaId, body.captcha)) return fail(res, 422, '验证码不正确，请重新输入');
    if (findUserByName(username)) return fail(res, 409, '该用户名已被占用');
    const salt = crypto.randomBytes(16).toString('hex');
    const user = {
      id: uid('u'),
      username,
      nickname: nickname.slice(0, 24),
      avatar: str(body.avatar, 300000),
      bio: str(body.bio, 60),
      phone,
      gender: normalizeGender(body.gender),
      balance: 0,                                    // 零钱余额（付款方式里可以选「余额」）
      transferLimit: 20000,                          // 单笔转账限额（0 = 不限）
      salt,
      passwordHash: hashPassword(password, salt),
      createdAt: now()
    };
    db.users.push(user);
    saveUsers();
    attachBotsFor(user);      // 新用户也要有机器人（朋友 + 欢迎会话），否则会话列表是空的
    noteSignupRisk(user, req);   // 风控：同 IP 批量注册（要在记安全事件之前算，才算得准）
    recordSecurity(user.id, req, 'register');
    ok(res, { user: publicUser(user) },
      { 'Set-Cookie': sessionCookie(signToken(user.id, req), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  /* ------------------------------------------------ 手机号登录（外壳那套） */
  // 发验证码：本地没接短信通道，所以直接把码返回给前台显示，方便自己用
  if (parts[0] === 'login' && parts[1] === 'phone-code' && method === 'POST') {
    const body = await readBody(req);
    const phone = normalizePhone(body.phone);
    if (!/^1[3-9]\d{9}$/.test(phone)) return fail(res, 422, '手机号格式不对，要 11 位手机号');
    /* 这个接口能试出「某个手机号有没有绑定账号」，所以单独限流，防止有人拿号码库来撞 */
    if (!phoneCodeRateAllow(clientInfo(req).ip)) {
      strikeIp(clientInfo(req).ip, '狂刷手机号验证码');
      return fail(res, 429, '试得太频繁了，10 分钟后再试');
    }
    const user = db.users.find((u) => normalizePhone(u.phone) === phone);
    if (!user) return fail(res, 404, '这个手机号还没有绑定账号，先用账号密码登录，在「手机号」里绑定');
    if (user.banned) return fail(res, 403, banMsg(user));
    if (user.frozen) return fail(res, 403, frozenMsg(user));      // CHRIS_FREEZE_V1
    const code = String(Math.floor(100000 + Math.random() * 900000));
    phoneCodes.set(phone, { code, userId: user.id, expiresAt: Date.now() + 5 * 60 * 1000 });
    recordSecurity(user.id, req, 'phone-code', { phone });
    /* 配了短信通道就真发短信；没配就是「开发模式」：只写日志 + 局域网内直接显示 */
    const smsCfg = readSmsCfg();
    let smsResult = { ok: false, error: '短信没配置' };
    if (smsReady(smsCfg)) smsResult = await sendSmsCode(phone, code, smsCfg);
    if (smsReady(smsCfg) && !smsResult.ok) {
      phoneCodes.delete(phone);
      return fail(res, 502, '短信没发出去：' + smsResult.error);
    }
    /* 安全：验证码以前直接写在响应里，知道手机号就能登进别人账号。
       现在只有本机/局域网（你自己的手机、你自己的电脑）才拿得到，外网请求只提示「已发送」。 */
    const fromLan = isLanAddress(peerIp(req));
    console.log('[手机号登录] ' + phone + ' 验证码 ' + code + ' ← ' + clientInfo(req).ip);
    if (smsResult.ok) {
      ok(res, { sent: true, sms: true, nickname: fromLan ? user.nickname : '', note: '验证码已发到手机，5 分钟内有效' });
      return;
    }
    ok(res, fromLan
      ? { sent: true, devCode: code, nickname: user.nickname, note: '没接短信通道，局域网内直接显示，5 分钟内有效' }
      : { sent: true, nickname: '', note: '验证码已发送，请在手机上看（外网不返回验证码）' });
    return;
  }

  /* 密码找回：手机号 + 验证码 + 新密码（对应功能清单里的「密码找回」）
     验证码复用「手机号登录」那套，5 分钟有效；改完直接把当前设备登进去 */
  if (parts[0] === 'login' && parts[1] === 'reset' && method === 'POST') {
    const body = await readBody(req);
    const phone = normalizePhone(body.phone);
    const code = str(body.code, 8);
    const nextPwd = String(body.newPassword || '');
    const rec = phoneCodes.get(phone);
    if (!rec || rec.expiresAt < Date.now()) return fail(res, 422, '验证码过期了，请重新获取');
    if (rec.code !== code) return fail(res, 401, '验证码不对');
    if (nextPwd.length < 6) return fail(res, 422, '新密码至少 6 位');
    const target = findUser(rec.userId);
    if (!target) return fail(res, 404, '账号不存在');
    if (target.banned) return fail(res, 403, banMsg(target));
    const salt = crypto.randomBytes(16).toString('hex');
    target.salt = salt;
    target.passwordHash = hashPassword(nextPwd, salt);
    sysNotice(target.id, '你的账号密码被客服重置了（如果不是你申请的，请马上联系客服）。', '安全提醒', 'security');
    target.passwordUpdatedAt = now();
    target.tokenVersion = (target.tokenVersion || 0) + 1;
    saveUsers();
    phoneCodes.delete(phone);
    recordSecurity(target.id, req, 'reset-password', { phone: phone });
    ok(res, { user: publicUser(target), reset: true },
      { 'Set-Cookie': sessionCookie(signToken(target.id, req), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  // 用手机号 + 验证码登录
  if (parts[0] === 'login' && parts[1] === 'phone' && method === 'POST') {
    const body = await readBody(req);
    const phone = normalizePhone(body.phone);
    const code = str(body.code, 8);
    const rec = phoneCodes.get(phone);
    if (!rec || rec.expiresAt < Date.now()) return fail(res, 422, '验证码过期了，请重新获取');
    if (rec.code !== code) return fail(res, 401, '验证码不对');
    const user = findUser(rec.userId);
    if (!user) return fail(res, 404, '账号不存在');
    if (user.banned) return fail(res, 403, banMsg(user));
    if (user.frozen) return fail(res, 403, frozenMsg(user));      // CHRIS_FREEZE_V1
    phoneCodes.delete(phone);
    rememberDevice(user, req);      // 短信登录也记设备（换设备登录才会被要求验证）
    kickOtherPhones(user, req);     // 手机单点登录：新手机一登，旧手机立刻下线
    saveUsers();
    noteLoginRisk(user, req);   // 风控：新设备 / 同 IP 多账号（要在记安全事件之前算）
    recordSecurity(user.id, req, 'login');
    ok(res, { user: publicUser(user) },
      { 'Set-Cookie': sessionCookie(signToken(user.id, req), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  if (parts[0] === 'login' && method === 'POST') {
    const body = await readBody(req);
    const rawName = str(body.username, 24);
    /* 滑动验证：**默认不弹**（正常登录一路过，跟微信一样）。
       票是一次性的（/api/slider/verify 滑对才发、用过即废）；
       只有 loginNeedsSlider() 判定有风险才回 428，
       客户端看到 details.needSlider 再把滑块「弹出来」。
       想整层关掉：data/security.json 里写 "sliderLogin": 0。 */
    if (!consumeSliderTicket(body.sliderTicket) && secCfg().sliderLogin) {
      const guess = findUserByName(rawName);
      if (guess && !guess.banned && loginNeedsSlider(req, guess)) {
        return fail(res, 428, '请完成安全验证', { needSlider: true });
      }
    }
    const ip = clientInfo(req).ip;
    const kUser = 'u:' + rawName.toLowerCase();
    const kIp = 'ip:' + ip;
    const wait = Math.max(loginBlocked(kUser), loginBlocked(kIp));
    if (wait) return fail(res, 429, '密码错误次数太多，请 ' + Math.ceil(wait / 60) + ' 分钟后再试');
    const user = findUserByName(rawName);
    if (!user || !verifyPassword(user, String(body.password || ''))) {
      noteLoginFail(kUser);
      noteLoginFail(kIp);
      return fail(res, 401, '用户名或密码不正确');
    }
    if (user.banned) return fail(res, 403, banMsg(user));
    if (user.frozen) return fail(res, 403, frozenMsg(user));      // CHRIS_FREEZE_V1
    clearLoginFails([kUser, kIp]);
    rememberDevice(user, req);      // 这台设备登过这个账号了：下次同一台设备直接过
    kickOtherPhones(user, req);     // 手机单点登录：新手机一登，旧手机立刻下线
    saveUsers();
    noteLoginRisk(user, req);   // 风控：新设备 / 同 IP 多账号（要在记安全事件之前算）
    recordSecurity(user.id, req, 'login');
    ok(res, { user: publicUser(user) },
      { 'Set-Cookie': sessionCookie(signToken(user.id, req), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  /* 身份证自助解封：被封的账号在登录页填「账号 + 密码 + 身份证号」就能自己解开 */
  /* ============================================================ 冻结 / 解冻（CHRIS_FREEZE_V1）
     2026-10-12 用户要求「把微信的真实封号和解冻、可以自己冻结做出来对齐」：
       · 自己冻结：POST /api/me/freeze（登录态；设过登录密码要先验密码）
         —— 冻上以后所有设备都会拿到 403，App 自己退回登录页并显示原因
       · 自助解冻：POST /api/account/unfreeze（不需要登录；账号 + 密码 +（可选）实名身份证号）
         —— 解开之后直接把登录态发下去（和「身份证自助解封」同一套写法）
       · 查状态：GET /api/account/state?u=账号 → 登录页用它决定提示「被冻结」还是「被禁用」
       · 管理侧：POST /api/ops/account（冻结 / 解冻 / 封禁 / 解封，带原因）
     ============================================================ */
  if (parts[0] === 'account' && parts[1] === 'state' && method === 'GET') {
    const q = str(query.get('u'), 24);
    const u = findUserByName(q) || (normalizePhone(q) ? db.users.find((x) => normalizePhone(x.phone) && normalizePhone(x.phone) === normalizePhone(q)) : null);   // CHRIS_FREEZE_V1b
    ok(res, {
      exists: !!u,
      banned: !!(u && u.banned),
      frozen: !!(u && u.frozen),
      reason: u ? (u.banned ? (u.banReason || '') : (u.frozenReason || '')) : ''
    });
    return;
  }

  if (parts[0] === 'account' && parts[1] === 'unfreeze' && method === 'POST') {
    const body = await readBody(req);
    const ip = clientInfo(req).ip;
    if (!unbanRateAllow(ip)) return fail(res, 429, '试得太频繁了，10 分钟后再试');
    const rawName = str(body.username, 24);
    const u = findUserByName(rawName)
      || (normalizePhone(rawName) ? db.users.find((x) => normalizePhone(x.phone) && normalizePhone(x.phone) === normalizePhone(rawName)) : null);   // CHRIS_FREEZE_V1b
    if (!u) return fail(res, 404, '这个账号不存在');
    if (!verifyPassword(u, String(body.password || ''))) {
      noteLoginFail('u:' + u.username);
      noteLoginFail('ip:' + ip);
      return fail(res, 401, '账号或密码不对');
    }
    if (!u.frozen) return fail(res, 409, '这个账号没有被冻结，直接登录就行');
    const idc = normalizeIdCard(body.idCard);
    if (idc) {
      if (!isValidIdCard(idc)) {
        return fail(res, 422, '身份证号不合法：要 18 位，前 6 位是地区、中间 8 位是生日、最后一位是校验位（可能是 X）');
      }
      const h = idCardHash(idc);
      if (u.idCardHash && u.idCardHash !== h) {
        return fail(res, 403, '这张身份证和这个账号之前实名登记的不一致');
      }
      const taken = db.users.find((x) => x.id !== u.id && x.idCardHash === h);
      if (taken) return fail(res, 403, '这张身份证已经绑定过其它账号了，请联系管理员');
      u.idCardHash = h;
      u.idCardMask = maskIdCard(idc);
      u.idCardVerifiedAt = now();
      u.realNameVerified = true;
    }
    u.frozen = false;
    u.frozenAt = 0;
    u.frozenReason = '';
    saveUsers();
    recordSecurity(u.id, req, 'unfreeze-self');
    audit(req, { username: u.username, name: u.nickname, role: '用户自助' },
      '自助解冻账号', u.username, idc ? maskIdCard(idc) : '只验了密码');
    ok(res, { unfrozen: true, user: publicUser(u), note: '已解冻，正在登录…' },
      { 'Set-Cookie': sessionCookie(signToken(u.id, req), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  if (parts[0] === 'me' && parts[1] === 'freeze' && method === 'POST') {
    const body = await readBody(req);
    if (user.frozen) return fail(res, 409, '这个账号已经冻结了');
    const hasPwd = !!user.passwordHash;
    if (hasPwd && !verifyPassword(user, String(body.password || ''))) {
      return fail(res, 401, '密码不对：冻结账号前要先验证登录密码');
    }
    user.frozen = true;
    user.frozenAt = now();
    user.frozenReason = str(body.reason, 40) || (hasPwd ? '本人操作' : '本人操作（未设登录密码）');
    saveUsers();
    closeUserConnections(user.id);            // 所有设备立刻掉线
    recordSecurity(user.id, req, 'freeze-self');
    audit(req, { username: user.username, name: user.nickname, role: '本人' },
      '冻结自己的账号', user.username, user.frozenReason);
    ok(res, { frozen: true, reason: user.frozenReason });
    return;
  }

  if (parts[0] === 'ops' && parts[1] === 'account' && method === 'POST') {
    if (!isOpsUser(user)) return fail(res, 403, '没有权限');
    const body = await readBody(req);
    const t = findUser(String(body.userId || ''));
    if (!t) return fail(res, 404, '用户不存在');
    const act = String(body.action || '').trim();
    const why = str(body.reason, 100);
    if (act === 'freeze') {
      t.frozen = true; t.frozenAt = now(); t.frozenReason = why || '管理员冻结';
      saveUsers(); closeUserConnections(t.id);
    } else if (act === 'unfreeze') {
      t.frozen = false; t.frozenAt = 0; t.frozenReason = '';
      saveUsers();
    } else if (act === 'ban') {
      setUserBanned(t, true, why || '违规', user.username);
    } else if (act === 'unban') {
      setUserBanned(t, false, '', user.username);
    } else {
      return fail(res, 400, 'action 只能是 freeze / unfreeze / ban / unban');
    }
    audit(req, { username: user.username, name: user.nickname, role: '管理' },
      '账号状态：' + act, t.username, why || '');
    ok(res, {
      user: {
        id: t.id, username: t.username, nickname: t.nickname,
        banned: !!t.banned, frozen: !!t.frozen,
        reason: t.banned ? (t.banReason || '') : (t.frozenReason || '')
      }
    });
    return;
  }

  /* ============================================================ 漂流瓶（CHRIS_BOTTLE_V1）
     2026-10-12 用户：「摇一摇改成漂流瓶」。
       · POST /api/bottle/throw  { text }        → 扔一个瓶子（最多 200 字）
       · POST /api/bottle/pick                  → 捞一个（别人的、我没捞过的；海里没有就回 empty）
       · GET  /api/bottle/count                 → 海里现在有多少瓶子
     数据落 data/bottles.json，最多留 500 个（老的自动滚掉）；每个瓶子记住谁捞过，
     同一个人不会反复捞到同一个。看不到是谁扔的（只给昵称），和微信一样。
     ============================================================ */
  const BOTTLE_FILE = 'bottles.json';
  const BOTTLE_MAX = 500;
  /* CHRIS_BOTTLE_SEED_V1：海里空的时候先放几个「官方瓶」——
     用户反馈「漂流瓶里也没内容」：一个人都没扔过，捞自然什么都捞不到。
     这些瓶子 system:true，谁都能捞到、不会被捞空，也不占别人的名额。 */
  const BOTTLE_SEEDS = [
    '在海边捡到过一颗会发光的贝壳，它好像在等谁回来。',
    '今天把想说的话写在纸上，折成小船放进了水里。',
    '陌生人你好，希望你今天遇到的事都刚刚好。',
    '记得吃饭，记得早睡，记得有人在想你。',
    '如果此刻你也不开心，就当这个瓶子是我递给你的糖。',
    '想去看一次海，把烦恼都扔进去。',
    /* 2026-10-13 又加了一批（用户「漂流瓶没有任何内容」）：海里一直有东西可捞 */
    '愿你今天走的路，都是你自己想走的那条。',
    '如果你也睡不着，我们就当隔着一片海在聊天。',
    '把烦恼写下来丢进海里吧，它沉下去，你浮起来。',
    '今天有好好吃饭吗？没有的话，现在去。',
    '别急，慢慢来，好的事都在路上。',
    '我猜你现在应该挺累的，抱一下。',
    '海很大，你想不开的那件事，其实没多大。',
    '希望下一个浪把好消息带给你。',
    '有些话说不出口，就让瓶子替我说。',
    '你已经做得比自己以为的好了。',
    '如果你捡到这个瓶子，说明我们今天有点缘分。',
    '把心放轻一点，路会好走很多。',
    '想告诉你：天黑之后，海还是海。',
    '陌生人，愿你的手机电量永远是满的，愿你等的人正在赶来。',
    '今天不开心也没关系，明天再说。',
    '祝你今天遇到的人，都比昨天温柔一点。',
    '把窗户开一条缝，让风进来，也让它把烦的事带走。',
    '我在很远的地方，也祝你平安。',
    '如果你愿意，回一句也行 —— 大海会替我收着。'
  ];
  function bottleSeedList() {
    return BOTTLE_SEEDS.map((t, i) => ({
      id: 'bt_seed_' + i, text: t, fromId: '__sea__', fromName: '大海', at: now(),
      pickedBy: [], system: true
    }));
  }
  function readBottles() {
    const f = path.join(DATA_DIR, BOTTLE_FILE);
    const b = readJson(f, null);
    if (!b || !Array.isArray(b.bottles)) { const s0 = { bottles: bottleSeedList() }; writeJson(f, s0); return s0; }
    /* CHRIS_BOTTLE_SEED_V2：**按 id 一个一个补**（以前是「一条官方瓶都没有才补」——
       后来官方瓶从 6 条加到 24 条时，老数据里已经有 6 条了，新的那批**永远补不上**，
       用户那边就显得"海里没东西"）。现在缺哪条补哪条。 */
    const seeds = bottleSeedList();
    const have = new Set(b.bottles.filter((x) => x).map((x) => String(x.id)));
    const missing = seeds.filter((s) => !have.has(s.id));
    if (missing.length) { b.bottles = b.bottles.concat(missing); writeJson(f, b); }
    return b;
  }
  function saveBottles(b) { writeJson(path.join(DATA_DIR, BOTTLE_FILE), b); }

  if (parts[0] === 'bottle' && parts[1] === 'count' && method === 'GET') {
    /* CHRIS_BOTTLE_TRACE_V1：谁在什么时候问了「海里几个瓶子」——
       用户报「漂流瓶没有任何内容」时，先看这条：有记录 = 页面进去了，
       没记录 = 根本没进到这一页（问题在入口，不在数据）。 */
    const bb = readBottles();
    try { callTrace('bottle count by ' + (user.username || user.id) + ' 海里=' + bb.bottles.length); } catch (e) { }
    ok(res, { total: bb.bottles.length });
    return;
  }

  if (parts[0] === 'bottle' && parts[1] === 'throw' && method === 'POST') {
    const body = await readBody(req);
    const text = str(body.text, 200).trim();
    if (!text) return fail(res, 422, '先写一句话再扔');
    if (!bottleRateAllow(user.id)) return fail(res, 429, '扔得太快了，歇一会儿再扔');
    const b = readBottles();
    b.bottles.push({
      id: uid('bt'), text: text, fromId: user.id,
      fromName: user.nickname || user.username || '', at: now(), pickedBy: []
    });
    if (b.bottles.length > BOTTLE_MAX) b.bottles = b.bottles.slice(-BOTTLE_MAX);
    saveBottles(b);
    try { callTrace('bottle throw by ' + (user.username || user.id) + ' 海里=' + b.bottles.length); } catch (e) { }
    ok(res, { thrown: true, total: b.bottles.length });
    return;
  }

  if (parts[0] === 'bottle' && parts[1] === 'pick' && method === 'POST') {
    if (!bottleRateAllow(user.id)) return fail(res, 429, '捞得太快了，歇一会儿再捞');
    const b = readBottles();
    /* 先捞别人的真瓶子；真瓶子捞完了就捞「官方瓶」（system:true，谁都能捞、捞不光） */
    let pool = b.bottles.filter((x) => x && !x.system && x.fromId !== user.id && !(x.pickedBy || []).includes(user.id));
    let fromSeed = false;
    if (!pool.length) {
      pool = b.bottles.filter((x) => x && x.system);
      fromSeed = true;
    }
    if (!pool.length) { ok(res, { bottle: null, empty: true, total: b.bottles.length }); return; }
    const one = pool[Math.floor(Math.random() * pool.length)];
    if (!fromSeed) {
      one.pickedBy = (one.pickedBy || []).concat([user.id]).slice(-80);
    }
    saveBottles(b);
    try {
      callTrace('bottle pick by ' + (user.username || user.id) + ' 捞到=' + one.id
        + (fromSeed ? '(官方瓶)' : '(真人瓶)') + ' 海里=' + b.bottles.length);
    } catch (e) { }
    ok(res, { bottle: { id: one.id, text: one.text, fromName: one.fromName || '', at: one.at },
              total: b.bottles.length });
    return;
  }

  if (parts[0] === 'unban' && method === 'POST') {
    const body = await readBody(req);
    const ip = clientInfo(req).ip;
    if (!unbanRateAllow(ip)) return fail(res, 429, '申请太频繁了，10 分钟后再试');
    const idc = normalizeIdCard(body.idCard);
    if (!isValidIdCard(idc)) {
      return fail(res, 422, '身份证号不合法：要 18 位，前 6 位是地区、中间 8 位是生日、最后一位是校验位（可能是 X）');
    }
    const rawName = str(body.username, 24);
    const user = findUserByName(rawName)
      || db.users.find((u) => normalizePhone(u.phone) && normalizePhone(u.phone) === normalizePhone(rawName))
      || null;
    if (!user) return fail(res, 404, '这个账号不存在');
    if (!verifyPassword(user, String(body.password || ''))) {
      noteLoginFail('u:' + user.username);
      noteLoginFail('ip:' + ip);
      return fail(res, 401, '账号或密码不对');
    }
    if (!user.banned) return fail(res, 409, '这个账号没有被禁用，直接登录就行');
    const h = idCardHash(idc);
    /* 同一个账号第二次解封必须用同一张证；一张证只能绑一个账号 */
    if (user.idCardHash && user.idCardHash !== h) {
      return fail(res, 403, '这张身份证和这个账号之前实名登记的不一致');
    }
    const taken = db.users.find((u) => u.id !== user.id && u.idCardHash === h);
    if (taken) return fail(res, 403, '这张身份证已经绑定过其它账号了，请联系管理员');

    const reason = user.banReason || '';
    user.idCardHash = h;
    user.idCardMask = maskIdCard(idc);
    user.idCardVerifiedAt = now();
    user.realNameVerified = true;
    setUserBanned(user, false, '', '身份证自助解封');
    recordSecurity(user.id, req, 'unban-idcard');
    audit(req, { username: user.username, name: user.nickname, role: '用户自助' },
      '身份证自助解封', user.username, maskIdCard(idc) + '（原封禁原因：' + (reason || '未填写') + '）');
    ok(res, {
      unbanned: true, user: publicUser(user), idMask: maskIdCard(idc),
      note: '已解封，正在登录…'
    }, { 'Set-Cookie': sessionCookie(signToken(user.id, req), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  if (parts[0] === 'logout' && method === 'POST') {
    ok(res, { loggedOut: true }, { 'Set-Cookie': sessionCookie('', 0) });
    return;
  }

  if (parts[0] === 'session') {
    /* 被封禁的账号：登录态即使还在，也要明确告诉 App「你被禁用了」，
       这样手机端会退到登录页并显示原因，而不是继续用缓存的资料硬撑。 */
    if (user && (user.banned || user.frozen)) {          // CHRIS_FREEZE_V1
      ok(res, {
        authenticated: false, banned: !!user.banned, frozen: !!user.frozen,
        reason: user.banned ? (user.banReason || '') : (user.frozenReason || ''),
        bannedAt: user.bannedAt || 0
      });
      return;
    }
    ok(res, { authenticated: !!user, user: publicUser(user) });
    return;
  }
  /* 一封到底：被封禁的账号，除了上面的登录/会话接口，其它接口一律 403。
     （封禁时 tokenVersion 已经 +1，旧 token 本来就失效了；
       这里再兜一道，防止有设备拿着旧版本号或换新 token 绕进来。） */
  if (user && user.banned) {
    return fail(res, 403, banMsg(user));
  }
  /* CHRIS_FREEZE_V1：被冻结的账号（本人冻的或管理冻的）在这台手机上直接踢到登录页 */
  if (user && user.frozen) {
    return fail(res, 403, frozenMsg(user));
  }
  if (!user) {
    /* 手机在别处登录了：明确回一个 code，App 收到就弹「已在别处登录」卡片 */
    if (req.__otherLogin) return fail(res, 401, '你的账号在另一台设备上登录了', { code: 'other_login' });
    /* 同上：只有没带任何令牌的裸请求才记 strike，令牌过期不记（不然一个 IP 会被自己人刷爆） */
    if (!req.headers.authorization && !req.headers.cookie) {
      strikeIp(clientInfo(req).ip, '裸请求取数据 ' + parts[0]);
    }
    fail(res, 401, '请先登录');
    return;
  }

  /* 登录设备管理（微信「我 → 设置 → 账号与安全 → 登录设备管理」）：
     每台登录过的设备一条（重装的 App 换 deviceId 也算一台），最后登录时间倒序，
     当前这台标 current=true。记录是登录时 rememberDevice() 写进 user.devices 的。 */
  /* 音乐曲库（App「听一听」）：登录后就能看，发卡片也是拿这里的歌 */
  /* 小程序 / 小游戏（App「发现 → 小程序」那一页 + 游戏页都用它）：
     ?kind=game 只要小游戏 */
  if (parts[0] === 'miniapps' && method === 'GET') {
    const onlyKind = String(query.get('kind') || '');
    ok(res, { items: miniAppList(onlyKind || null) });
    return;
  }

  if (parts[0] === 'music' && method === 'GET') {
    ok(res, { tracks: musicTracks() });
    return;
  }

  if (parts[0] === 'devices' && method === 'GET') {
    const cur = clientInfo(req);
    const rows = (Array.isArray(user.devices) ? user.devices : []).map((d) => ({
      id: d.id || '',
      name: d.name || '',
      device: d.device || '未知设备',
      /* 机型名优先（老记录存的是 iPhone17,1 这种机器号，这里映射成人看的名字） */
      model: friendlyModelName(d.model) || friendlyModelName(d.deviceMachine) || '',
      os: d.os || '',
      ip: d.ip || '',
      /* ⚠ 必须是毫秒数字：以前给 ISO 字符串，客户端解不出来整页就空了 */
      at: msOf(d.at),
      current: !!(cur.deviceId && d.id && d.id === cur.deviceId)
    }));
    /* 这台设备是「恢复会话」进来的（没走过登录那一步）也不能漏：列表里补一条本机 */
    if (cur.deviceId && !rows.some((d) => d.id === cur.deviceId)) {
      rows.unshift({ id: cur.deviceId, name: cur.name || '', device: cur.device || '',
                     model: friendlyModelName(cur.model) || '', os: cur.os || '', ip: cur.ip || '',
                     at: msOf(now()), current: true });
    }
    ok(res, {
      devices: rows,
      current: { id: cur.deviceId, device: cur.device, model: cur.model, os: cur.os, ip: cur.ip, at: now() }
    });
    return;
  }

  /* 登录设备管理 → 编辑 → 删除某个设备（只删记录 + 记一条安全事件） */
  if (parts[0] === 'devices' && parts[1] === 'remove' && method === 'POST') {
    const body = await readBody(req);
    const id = String(body.id || '');
    const cur = clientInfo(req);
    if (!id) return fail(res, 422, '缺少设备标识');
    if (cur.deviceId && id === cur.deviceId) return fail(res, 400, '不能删除当前设备');
    const list = Array.isArray(user.devices) ? user.devices : [];
    const hit = list.find((d) => (d.id || '') === id);
    user.devices = list.filter((d) => (d.id || '') !== id);
    saveUsers();
    recordSecurity(user.id, req, 'device-remove',
      { note: '删除登录设备：' + ((hit && (hit.name || hit.device)) || '未命名设备') });
    ok(res, { removed: !!hit, devices: user.devices.length });
    return;
  }

  /* 红点数字（很轻的一个接口）：手机端回到前台、或者长连接重连时拉一次，
     就算推送丢了也能把「新的朋友」的红点点亮 */
  if (parts[0] === 'badge-counts' && method === 'GET') {
    ok(res, {
      friendRequests: pendingFriendRequests(user.id),
      momentUnread: momentUnread(user.id)
    });
    return;
  }

  // 安全中心：登录记录 / 安全评分（必须放在通用的 /me 前面，否则会被它截走）
  if (parts[0] === 'me' && parts[1] === 'security' && method === 'GET') {
    const mine = db.security.logins.filter((x) => x.userId === user.id);
    const logins = mine.slice(0, 12).map((x) => ({
      id: x.id, kind: x.kind || 'login', time: x.time, ip: x.ip || '', device: x.device || '未知设备'
    }));
    const cur = clientInfo(req);
    ok(res, {
      score: securityScore(user, mine),
      credit: creditScore(user),                     // 安全分（550~850，三个维度）
      hasPhone: !!user.phone,
      changedPassword: !!user.passwordUpdatedAt,
      passwordUpdatedAt: user.passwordUpdatedAt || '',
      createdAt: user.createdAt || '',
      deviceCount: Object.keys(mine.reduce((a, x) => { a[x.device] = 1; return a; }, {})).length,
      hasPayPassword: hasPayPassword(user),
      payPasswordAt: user.payPasswordAt || '',
      current: cur,
      logins
    });
    return;
  }

  /* 转账付款：走服务端真扣余额（不够就付不了），并往会话里发一条转账消息 */
  /* 安全分：微信「支付分」那套（550~850 · 身份特质 / 支付行为 / 守约历史） */
  if (parts[0] === 'me' && parts[1] === 'score' && method === 'GET') {
    ok(res, { score: creditScore(user) });
    return;
  }

  /* ---------------- 经营账户（钱包 → 经营账户） ---------------- */
  if (parts[0] === 'biz' && method === 'GET') {
    const acc = bizOf(user.id, true);
    const day0 = localDayStart();
    const monthPrefix = new Date().toISOString().slice(0, 7);
    const collects = acc.records.filter((r) => r.kind === 'collect');
    const sum = (list) => Math.round(list.reduce((a, r) => a + (Number(r.amount) || 0), 0) * 100) / 100;
    ok(res, {
      enabled: acc.enabled,
      balance: acc.balance,
      settings: acc.settings,
      invoice: acc.invoice,
      records: acc.records.slice(0, 100),
      invoices: acc.invoices.slice(0, 50),
      totals: {
        today: sum(collects.filter((r) => new Date(r.createdAt).getTime() >= day0)),
        month: sum(collects.filter((r) => String(r.createdAt).slice(0, 7) === monthPrefix)),
        all: sum(collects),
        count: collects.length,
        withdrawn: sum(acc.records.filter((r) => r.kind === 'withdraw'))
      },
      invoiceReady: !!(acc.invoice.title && acc.invoice.taxNo)
    });
    return;
  }

  /* 经营设置（店主自己改） */
  if (parts[0] === 'biz' && parts[1] === 'settings' && method === 'POST') {
    const body = await readBody(req);
    const acc = bizOf(user.id, true);
    const s = acc.settings;
    if (body.enabled !== undefined) acc.enabled = !!body.enabled;
    if (body.arrival !== undefined) s.arrival = body.arrival === 'biz' ? 'biz' : 'balance';
    if (body.notify !== undefined) s.notify = !!body.notify;
    if (body.autoWithdraw !== undefined) s.autoWithdraw = !!body.autoWithdraw;
    if (body.shopName !== undefined) s.shopName = str(body.shopName, 30);
    if (body.remark !== undefined) s.remark = str(body.remark, 60);
    if (body.settle !== undefined) s.settle = str(body.settle, 10) || 'T+1';
    saveBizAll();
    ok(res, { enabled: acc.enabled, settings: s });
    return;
  }

  /* 开票信息（抬头 / 税号 / 地址电话 / 开户行账号） */
  if (parts[0] === 'biz' && parts[1] === 'invoice' && parts[2] !== 'apply' && method === 'POST') {
    const body = await readBody(req);
    const acc = bizOf(user.id, true);
    ['title', 'taxNo', 'address', 'phone', 'bankName', 'bankAccount'].forEach((k) => {
      if (body[k] !== undefined) acc.invoice[k] = str(body[k], 60);
    });
    saveBizAll();
    ok(res, { invoice: acc.invoice });
    return;
  }

  /* 申请开票：按金额开一张票，后台「经营账户查账」里处理 */
  if (parts[0] === 'biz' && parts[1] === 'invoice' && parts[2] === 'apply' && method === 'POST') {
    const body = await readBody(req);
    const acc = bizOf(user.id, true);
    if (!acc.invoice.title || !acc.invoice.taxNo) return fail(res, 422, '先把开票信息填上（抬头 + 税号）');
    const amount = rpRound2(body.amount);
    if (!(amount > 0)) return fail(res, 422, '开票金额要大于 0');
    const collects = Math.round(acc.records.filter((r) => r.kind === 'collect')
      .reduce((a, r) => a + (Number(r.amount) || 0), 0) * 100) / 100;
    const already = Math.round(acc.invoices.reduce((a, i) => a + (Number(i.amount) || 0), 0) * 100) / 100;
    if (amount > collects - already + 0.001) {
      return fail(res, 422, '可开票金额只有 ¥' + (collects - already).toFixed(2));
    }
    const inv = {
      id: uid('inv'), amount, status: 'pending', note: str(body.note, 60),
      title: acc.invoice.title, taxNo: acc.invoice.taxNo,
      kind: body.kind === 'company' ? 'company' : 'personal',
      createdAt: now(), handledAt: ''
    };
    acc.invoices.unshift(inv);
    if (acc.invoices.length > 300) acc.invoices.length = 300;
    bizPush(user.id, { kind: 'invoice', amount, note: '申请开票', status: 'pending' });
    saveBizAll();
    ok(res, { invoice: inv, invoices: acc.invoices.slice(0, 50) });
    return;
  }

  /* 提现到零钱（也可以用「全部提现」） */
  if (parts[0] === 'biz' && parts[1] === 'withdraw' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const body = await readBody(req);
    const acc = bizOf(user.id, true);
    const all = body.all === true;
    let amount = all ? acc.balance : rpRound2(body.amount);
    if (!(amount > 0)) return fail(res, 422, '经营账户里还没有可提现的钱');
    if (amount > acc.balance + 0.001) return fail(res, 422, '最多只能提 ¥' + acc.balance.toFixed(2));
    /* 经营账户提现也要支付密码（钱出去的口子一个都不能漏） */
    if (payPasswordGate(req, res, user, body, '经营账户提现')) return;
    acc.balance = Math.round((acc.balance - amount) * 100) / 100;
    user.balance = Math.round(((Number(user.balance) || 0) + amount) * 100) / 100;
    saveUsers();
    bizPush(user.id, { kind: 'withdraw', amount, note: '提现到零钱', method: 'balance' });
    saveBizAll();
    sendTo(user.id, { type: 'balance', balance: user.balance });
    ok(res, { balance: user.balance, bizBalance: acc.balance, amount });
    return;
  }

  /* ---------------- 支付分（钱包 → 支付分） ---------------- */
  /* ---------------- 青少年模式（设置 → 青少年模式） ---------------- */
  if (parts[0] === 'me' && parts[1] === 'teen' && method === 'GET') {
    ok(res, { teen: teenCfg(user) });
    return;
  }
  /* 第一次：设密码（4 位数字） */
  if (parts[0] === 'me' && parts[1] === 'teen' && parts[2] === 'setup' && method === 'POST') {
    const body = await readBody(req);
    const pin = String(body.pin || '').trim();
    if (!/^\d{4}$/.test(pin)) return fail(res, 422, '密码要 4 位数字');
    if (user.teen && user.teen.salt && user.teen.hash) return fail(res, 409, '已经设过密码了，忘了密码只能找管理员重置');
    const salt = crypto.randomBytes(16).toString('hex');
    user.teen = Object.assign({}, user.teen || {}, {
      salt: salt, hash: hashPassword(pin, salt), enabled: true,
      scopes: Object.assign({}, DEFAULT_TEEN_SCOPES, (user.teen && user.teen.scopes) || {}),
      setAt: now()
    });
    saveUsers();
    ok(res, { teen: teenCfg(user) });
    return;
  }
  /* 开关 / 改受限项 / 监护人手机号：都要密码 */
  if (parts[0] === 'me' && parts[1] === 'teen' && parts[2] === 'set' && method === 'POST') {
    const body = await readBody(req);
    const t = user.teen || {};
    if (!(t.salt && t.hash)) return fail(res, 409, '先设一个密码');
    const pin = String(body.pin || '').trim();
    if (!verifySecretRecord({ salt: t.salt, hash: t.hash }, pin)) return fail(res, 422, '密码不正确');
    if (body.enabled !== undefined) t.enabled = !!body.enabled;
    if (body.scopes && typeof body.scopes === 'object') {
      t.scopes = Object.assign({}, DEFAULT_TEEN_SCOPES, t.scopes || {});
      Object.keys(DEFAULT_TEEN_SCOPES).forEach((k) => { if (body.scopes[k] !== undefined) t.scopes[k] = body.scopes[k] ? 1 : 0; });
    }
    /* 使用时长 / 宵禁 / 支付上限（家长设定） */
    if (body.limits && typeof body.limits === 'object') {
      const L = Object.assign({}, DEFAULT_TEEN_LIMITS, t.limits || {});
      if (body.limits.dailyMinutes !== undefined) {
        L.dailyMinutes = Math.max(0, Math.min(1440, Math.round(Number(body.limits.dailyMinutes) || 0)));
      }
      if (body.limits.curfewOn !== undefined) L.curfewOn = body.limits.curfewOn ? 1 : 0;
      if (hhmm(body.limits.curfewStart) !== null) L.curfewStart = String(body.limits.curfewStart);
      if (hhmm(body.limits.curfewEnd) !== null) L.curfewEnd = String(body.limits.curfewEnd);
      if (body.limits.payLimit !== undefined) {
        const v = Number(body.limits.payLimit);
        L.payLimit = v < 0 ? -1 : Math.max(0, Math.min(100000, Math.round(v)));
      }
      t.limits = L;
    }
    if (body.guardianPhone !== undefined) {
      const ph = String(body.guardianPhone || '').replace(/\D/g, '');
      t.guardianPhoneMask = ph.length === 11 ? (ph.slice(0, 3) + '****' + ph.slice(7)) : '';
    }
    /* 家长临时解锁：给 5~60 分钟（到点自动又锁上） */
    if (body.unlockMinutes !== undefined) {
      const m = Math.max(5, Math.min(60, Math.round(Number(body.unlockMinutes) || 0)));
      t.unlockUntil = Date.now() + m * 60 * 1000;
    }
    if (body.relock === true) t.unlockUntil = 0;
    user.teen = t;
    saveUsers();
    ok(res, { teen: teenCfg(user) });
    return;
  }

  /* 使用时长上报（App 在前台每 30~60 秒报一次）—— 这一个是**不许权限**的：
     报了才有得管；服务端把一次最多认 10 分钟、一天最多认 24 小时，防着被灌数据。 */
  if (parts[0] === 'me' && parts[1] === 'teen' && parts[2] === 'usage' && method === 'POST') {
    const body = await readBody(req);
    const t = user.teen || {};
    if (!t.enabled) { ok(res, { teen: teenCfg(user) }); return; }
    const add = Math.max(0, Math.min(10, Math.round(Number(body.minutes) || 0)));
    const u = teenUsageOf(user);
    if (add > 0) {
      u.minutes = Math.min(24 * 60, u.minutes + add);
      t.usage = u;
      user.teen = t;
      saveUsers();
    }
    ok(res, { teen: teenCfg(user) });
    return;
  }

  if (parts[0] === 'me' && parts[1] === 'payscore' && method === 'GET') {
    ok(res, payScoreOf(user));
    return;
  }

  /* ---------------- 身份信息（钱包 → 身份信息）：实名 + 证件有效期/职业/常住地址 ---------------- */
  if (parts[0] === 'me' && parts[1] === 'identity' && method === 'GET') {
    const verified = !!(user.realName && user.idCardHash);
    ok(res, {
      verified,
      realName: verified ? (String(user.realName).slice(0, 1) + '*'.repeat(Math.max(1, String(user.realName).length - 1))) : '',
      idMask: user.idCardMask || '',
      verifiedAt: user.idCardVerifiedAt || '',
      idValid: user.idValid || '',                 // 证件有效期，比如 2035-08-01
      occupation: user.occupation || '',
      address: user.address || '',
      level: walletLevelInfo(user).level,
      levelName: walletLevelInfo(user).name,
      bankCount: Array.isArray(user.bankCards) ? user.bankCards.length : 0
    });
    return;
  }

  if (parts[0] === 'me' && parts[1] === 'identity' && method === 'POST') {
    const body = await readBody(req);
    if (body.idValid !== undefined) user.idValid = str(body.idValid, 20);
    if (body.occupation !== undefined) user.occupation = str(body.occupation, 20);
    if (body.address !== undefined) user.address = str(body.address, 60);
    saveUsers();
    ok(res, { saved: true, idValid: user.idValid || '', occupation: user.occupation || '', address: user.address || '' });
    return;
  }

  /* ---------------- 支付设置（钱包 → 支付设置）：免密支付 / 自动续费 / 支付方式 ---------------- */
  if (parts[0] === 'me' && parts[1] === 'paysettings' && method === 'GET') {
    ok(res, {
      hasPayPassword: hasPayPassword(user),
      noPin: !!user.noPin,                       // 小额免密支付（默认关）
      noPinLimit: Number(user.noPinLimit) || 1000,
      payMethod: user.payMethod === 'card' ? 'card' : 'balance',   // 首选付款方式
      autoDebits: Array.isArray(user.autoDebits) ? user.autoDebits : [],  // 自动续费/免密签约
      payPasswordUpdatedAt: user.payPasswordUpdatedAt || ''
    });
    return;
  }

  if (parts[0] === 'me' && parts[1] === 'paysettings' && method === 'POST') {
    const body = await readBody(req);
    if (body.noPin !== undefined) user.noPin = !!body.noPin;
    if (body.noPinLimit !== undefined) {
      const v = Number(body.noPinLimit);
      if ([0, 200, 500, 1000].indexOf(v) >= 0) user.noPinLimit = v || 1000;
    }
    if (body.payMethod !== undefined) user.payMethod = body.payMethod === 'card' ? 'card' : 'balance';
    /* 解约某个自动续费：传 id */
    if (body.cancelAutoDebit !== undefined) {
      const id = str(body.cancelAutoDebit, 40);
      user.autoDebits = (Array.isArray(user.autoDebits) ? user.autoDebits : []).filter((a) => a.id !== id);
    }
    saveUsers();
    ok(res, { saved: true });
    return;
  }

  /* 我的状态：24 小时还剩多久 + 谁看过（微信里点自己的状态能看到「X 人看过」） */
  if (parts[0] === 'me' && parts[1] === 'status' && method === 'GET') {
    const alive = moodAlive(user);
    const views = (Array.isArray(user.moodViews) ? user.moodViews : []).slice(-50).reverse();
    ok(res, {
      alive,
      moodText: alive ? (user.moodText || '') : '',
      moodIcon: alive ? (user.moodIcon || '') : '',
      moodColor: alive ? (user.moodColor || '') : '',
      moodColor2: alive ? (user.moodColor2 || '') : '',
      moodLabel: alive ? (user.moodLabel || user.moodText || '') : '',
      moodCaption: alive ? (user.moodCaption || '') : '',
      createdAt: user.moodAt || '',
      expiresAt: Number(user.moodExpiresAt) || 0,
      hoursLeft: alive && user.moodExpiresAt
        ? Math.max(0, Math.round((user.moodExpiresAt - Date.now()) / 3600000)) : 0,
      viewerCount: alive ? views.length : 0,
      views: views.map((v) => {
        const u = findUser(v.userId) || {};
        return { userId: v.userId, name: displayNameFor(user.id, u), avatar: u.avatar || '', at: v.at };
      })
    });
    return;
  }

  /* 结束我的状态（微信里可以手动结束） */
  if (parts[0] === 'me' && parts[1] === 'status' && method === 'POST') {
    /* 这条路径要跟下面「改在线状态」共用：带 status 的请求是改在线状态，交给下面的分支 */
    const moodBody = await readBody(req);
    const presenceWant = str(moodBody.status, 12);
    if (['online', 'busy', 'away', 'invisible'].includes(presenceWant)) {
      /* 不 return：往后走到「在线状态」那个分支去处理 */
    } else {
    user.moodText = '';
    user.moodLabel = '';
    user.moodCaption = '';
    user.moodKey = '';
    user.moodIcon = '';
    user.moodColor = '';
    user.moodColor2 = '';
    user.moodAt = '';
    user.moodExpiresAt = 0;
    user.moodViews = [];
    saveUsers();
    ok(res, { ended: true });
    return;
    }
  }

  /* ---------------- 账户升级服务（我 → 服务 → 钱包 → 账户升级服务） ---------------- */
  if (parts[0] === 'me' && parts[1] === 'wallet' && method === 'GET') {
    const info = walletLevelInfo(user);
    const real = !!(user.realName && user.idCardHash);
    const bankCount = Array.isArray(user.bankCards) ? user.bankCards.length : 0;
    const used = todayOutAmount(user.id);
    ok(res, {
      level: info.level,
      levelName: info.name,
      tip: info.tip,
      single: info.single,
      day: info.day,
      receive: info.receive,
      usedToday: used,
      leftToday: Math.round(Math.max(0, info.day - used) * 100) / 100,
      realName: real,
      realNameText: user.realName ? (String(user.realName).slice(0, 1) + '**') : '',
      idMask: user.idCardMask || '',
      bankCount,
      upgradedAt: user.walletUpgradedAt || '',
      levels: WALLET_LEVELS.map((l) => ({
        level: l.level, name: l.name, single: l.single, day: l.day,
        current: l.level === info.level, done: l.level <= info.level
      })),
      steps: [
        { key: 'realname', name: '实名认证', done: real, hint: '填姓名 + 身份证号，1 分钟搞定' },
        { key: 'bank', name: '绑定银行卡', done: bankCount > 0, hint: '只记银行名和末四位，卡号不留服务器' }
      ]
    });
    return;
  }

  /* 升级账户：该做的做完才算数（和微信一样，不是点一下就能升） */
  if (parts[0] === 'me' && parts[1] === 'wallet-upgrade' && method === 'POST') {
    const real = !!(user.realName && user.idCardHash);
    const bankCount = Array.isArray(user.bankCards) ? user.bankCards.length : 0;
    if (!real) return fail(res, 422, '先去「实名认证」把姓名和身份证号填上');
    if (!bankCount) return fail(res, 422, '先绑一张银行卡（只记末四位）');
    user.walletUpgradedAt = now();
    saveUsers();
    recordSecurity(user.id, req, 'wallet-upgrade');
    const info = walletLevelInfo(user);
    ok(res, { level: info.level, levelName: info.name, single: info.single, day: info.day });
    return;
  }

  /* 常见问题（独立一页：帮助与反馈 / 钱包底部进去；内容就是客服中心里配的那些问答） */
  if (parts[0] === 'faq' && method === 'GET') {
    const cfg = readSupport();
    const cats = (cfg.categories || []).map((c) => ({
      id: c.id || '',
      title: c.title || '',
      icon: c.icon || '',
      items: (c.items || []).filter((it) => it && it.q).map((it) => ({ q: it.q, a: it.a || '' }))
    })).filter((c) => c.items.length);
    ok(res, {
      title: '常见问题',
      searchHint: cfg.searchHint || '搜索你的问题',
      categories: cats,
      /* 热门：每个分类先拎一条出来（微信那页上面也有一栏热门问题） */
      hot: cats.map((c) => c.items[0]).filter(Boolean).slice(0, 6),
      contact: { phone: cfg.phone || '', email: cfg.email || '', workTime: cfg.workTime || '' }
    });
    return;
  }

  /* ---------------- 实名认证（填姓名 + 身份证号；一人一证） ---------------- */
  if (parts[0] === 'me' && parts[1] === 'realname' && method === 'GET') {
    ok(res, {
      verified: !!(user.realName && user.idCardHash),
      realName: user.realName ? String(user.realName).slice(0, 24) : '',   // 自己的实名，本人看全名
      idMask: user.idCardMask || '',
      at: user.idCardVerifiedAt || ''
    });
    return;
  }
  if (parts[0] === 'me' && parts[1] === 'realname' && method === 'POST') {
    const body = await readBody(req);
    const limitKey = user.id + ':' + clientInfo(req).ip;
    if (!realNameRateAllow(limitKey)) return fail(res, 429, '试得太频繁了，10 分钟后再试');

    const name = str(body.realName, 24).replace(/\s+/g, '');
    if (!(/^[\u4e00-\u9fa5·]{2,20}$/.test(name) || /^[A-Za-z][A-Za-z .]{1,38}$/.test(name))) {
      return fail(res, 422, '姓名要填真实的：中文 2~20 个字，或者英文名');
    }
    const idc = normalizeIdCard(body.idCard);
    if (!isValidIdCard(idc)) {
      return fail(res, 422, '身份证号不合法：要 18 位，前 6 位地区、中间 8 位生日、最后一位校验位（可能是 X）');
    }
    const h = idCardHash(idc);
    if (user.idCardHash && user.idCardHash === h && user.realName === name) {
      ok(res, { verified: true, realName: realNameOf(user), idMask: user.idCardMask || maskIdCard(idc), again: true });
      return;
    }
    if (user.idCardHash && user.idCardHash !== h) {
      return fail(res, 403, '这个账号已经实名过了，实名信息不能自己改，要改请联系管理员');
    }
    const taken = db.users.find((u) => u.id !== user.id && u.idCardHash === h);
    if (taken) return fail(res, 403, '这张身份证已经绑定过其它账号了，请联系管理员');

    user.realName = name;
    user.idCardHash = h;
    user.idCardMask = maskIdCard(idc);
    user.idCardVerifiedAt = now();
    user.realNameVerified = true;
    saveUsers();
    recordSecurity(user.id, req, 'realname');
    audit(req, { username: user.username, name: user.nickname, role: '用户本人' },
      '实名认证', user.username, name + ' · ' + maskIdCard(idc));
    ok(res, { verified: true, realName: name, idMask: maskIdCard(idc), at: user.idCardVerifiedAt });
    return;
  }

  /* 省 / 市（地区选择用）：和微信一样是两个滚轮，上下滑动选。数据不大，直接内置。 */
  if (parts[0] === 'regions' && method === 'GET') {
    ok(res, { regions: REGIONS.map((r) => ({ p: r[0], c: r[1] })) });
    return;
  }

  /* 换手机号（和微信一个流程）：① 给新号发验证码 ② 提交新号 + 验证码 ③ 换绑成功。
     手机号一年只能换一次（微信也是这规矩）；新号不能已经绑了别的账号；旧号自动解绑。 */
  if (parts[0] === 'me' && parts[1] === 'phone' && parts[2] === 'code' && method === 'POST') {
    const body = await readBody(req);
    const phone = normalizePhone(body.phone);
    if (!/^1[3-9]\d{9}$/.test(phone)) return fail(res, 422, '手机号格式不对，要 11 位手机号');
    const wait = phoneChangeWaitDays(user);
    if (wait > 0) return fail(res, 403, '手机号一年只能换一次，还要等 ' + wait + ' 天');
    if (normalizePhone(user.phone) === phone) return fail(res, 409, '这就是你现在绑定的手机号');
    const taken = db.users.find((u) => u.id !== user.id && normalizePhone(u.phone) === phone);
    if (taken) return fail(res, 409, '这个手机号已经绑定了其它账号');
    if (!phoneCodeRateAllow(clientInfo(req).ip)) {
      strikeIp(clientInfo(req).ip, '狂刷换手机号验证码');
      return fail(res, 429, '试得太频繁了，10 分钟后再试');
    }
    const code = String(Math.floor(100000 + Math.random() * 900000));
    phoneCodes.set(phone, { code, userId: user.id, expiresAt: Date.now() + 5 * 60 * 1000 });
    const smsCfg2 = readSmsCfg();
    let sms2 = { ok: false, error: '短信没配置' };
    if (smsReady(smsCfg2)) sms2 = await sendSmsCode(phone, code, smsCfg2);
    if (smsReady(smsCfg2) && !sms2.ok) {
      phoneCodes.delete(phone);
      return fail(res, 502, '短信没发出去：' + sms2.error);
    }
    console.log('[换手机号] ' + phone + ' 验证码 ' + code + ' ← ' + clientInfo(req).ip);
    /* 和安全口径一致：只有本机/局域网（你自己的手机）才把验证码直接显示出来 */
    const lan2 = isLanAddress(peerIp(req));
    if (sms2.ok) { ok(res, { sent: true, note: '验证码已发到手机，5 分钟内有效' }); return; }
    ok(res, { sent: true, devCode: lan2 ? code : '', note: '验证码已发送，5 分钟内有效' });
    return;
  }

  if (parts[0] === 'me' && parts[1] === 'phone' && method === 'POST') {
    const body = await readBody(req);
    const phone = normalizePhone(body.phone);
    const code = str(body.code, 8);
    if (!/^1[3-9]\d{9}$/.test(phone)) return fail(res, 422, '手机号格式不对，要 11 位手机号');
    const wait = phoneChangeWaitDays(user);
    if (wait > 0) return fail(res, 403, '手机号一年只能换一次，还要等 ' + wait + ' 天');
    /* 没接短信通道时（后台「短信通道」还没配），验证码根本发不出去 ——
       这种情况改用「当前登录密码」验证，不然这个功能对公网用户直接是废的。
       配了短信通道就严格按验证码来。 */
    if (!smsReady(readSmsCfg())) {
      if (!verifyPassword(user, String(body.password || ''))) {
        return fail(res, 422, '请填写当前账号的登录密码（还没配短信通道，用密码验证）');
      }
    } else {
      const rec = phoneCodes.get(phone);
      if (!rec || rec.userId !== user.id || rec.expiresAt < Date.now()) {
        return fail(res, 422, '验证码过期了，请重新获取');
      }
      if (rec.code !== code) return fail(res, 422, '验证码不对');
    }
    const taken = db.users.find((u) => u.id !== user.id && normalizePhone(u.phone) === phone);
    if (taken) return fail(res, 409, '这个手机号已经绑定了其它账号');
    phoneCodes.delete(phone);
    user.phone = phone;
    user.phoneChangedAt = now();
    saveUsers();
    recordSecurity(user.id, req, 'phone-change', { phone });
    audit(req, { username: user.username, name: user.nickname, role: '用户本人' },
      '更换手机号', user.username, phone.slice(0, 3) + '****' + phone.slice(7));
    ok(res, { phone: phone.slice(0, 3) + '****' + phone.slice(7) });
    return;
  }

  /* ================= 收付款（微信那套：付款码 + 收款码） =================
     付款码：18 位数字（和微信一样），60 秒一换，给商家/对方扫；
     收款码：一张固定的二维码，扫了给对方付款；「设置金额」出来的带金额码 24 小时有效。
     付款方要过支付密码 / 额度 / 余额三道检查，钱当时就到对方账上（商家收款即时到账），
     同时往两个人的会话里落一条转账记录（账单、经营账户查账都看得到）。 */

  if (parts[0] === 'pay' && parts[1] === 'code' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const code = newPayCode(user.id);
    const rec = payCodes.get(code) || { exp: Date.now() + PAY_CODE_TTL_MS };
    const url = payBaseUrl(req) + '/pay.html?c=' + code;
    const enc = QR.encode(url);
    ok(res, {
      code: code,
      grouped: code.replace(/(\d{4})(?=\d)/g, '$1 '),
      url: url,
      expiresAt: rec.exp,
      seconds: Math.max(1, Math.round((rec.exp - Date.now()) / 1000)),
      rows: enc ? enc.modules.map((r) => r.join('')) : [],
      size: enc ? enc.size : 0,
      user: publicUser(user)
    });
    return;
  }

  /* 收款码：不带金额 = 「我的收款码」；带 amount = 微信那种「设置金额」 */
  if (parts[0] === 'pay' && parts[1] === 'receive-code' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const body = await readBody(req);
    const amt = rpRound2(Number(body.amount) || 0);
    if (amt < 0 || amt > 200000) return fail(res, 422, '金额填得不对');
    const u = userCode(user.username);
    let url = payBaseUrl(req) + '/pay.html?u=' + encodeURIComponent(u);
    let exp = 0;
    if (amt > 0) {
      exp = Date.now() + 24 * 3600 * 1000;
      const a = amt.toFixed(2);
      url += '&a=' + a + '&e=' + exp + '&s=' + payAmountSig(u, a, exp);
    }
    const enc = QR.encode(url);
    ok(res, {
      url: url, amount: amt, expiresAt: exp,
      rows: enc ? enc.modules.map((r) => r.join('')) : [],
      size: enc ? enc.size : 0,
      user: publicUser(user)
    });
    return;
  }

  /* 扫到的字符串 → 这是谁的收付款码（客户端扫之前先问一下，免得把人都弄错） */
  if (parts[0] === 'pay' && parts[1] === 'resolve' && method === 'POST') {
    const body = await readBody(req);
    const found = resolvePayText(str(body.text || body.code, 400));
    if (found.error) return fail(res, 404, found.error);
    ok(res, { kind: found.kind, amount: found.amount || 0, user: publicUser(found.target) });
    return;
  }

  /* 扫码付款：付款码（对方扫我）/ 收款码（我扫对方）都走这里 */
  if (parts[0] === 'pay' && parts[1] === 'collect' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const body = await readBody(req);
    /* 幂等：扫码付款同样只允许扣一次（重发/连点都走同一笔） */
    const idem = idemBegin(user, body, 'collect');
    if (idem.dup) {
      if (idem.inflight) return fail(res, 409, '这笔正在处理，稍等一秒看余额再操作');
      return ok(res, idem.cached);
    }
    if (!payRateAllow(user.id)) return fail(res, 429, '付得太快了，歇一会儿再试');
    const found = resolvePayText(str(body.text || body.code, 400));
    if (found.error) return fail(res, 404, found.error);
    const target = found.target;
    if (target.id === user.id) return fail(res, 422, '不能给自己付钱');
    const face = !!body.face;
    const pwd = String(body.password || '').trim();
    let amount = rpRound2(Number(body.amount) || 0);
    if (found.kind === 'receive' && found.amount > 0) amount = found.amount;
    if (!(amount > 0)) return fail(res, 422, '请输入付款金额');
    if (amount > 200000) return fail(res, 422, '单笔最多 200000 元');
    /* 扫码付款同样要支付密码 */
    if (payPasswordGate(req, res, user, body, '扫码付款')) return;
    const lim = walletLimitCheck(user, amount);
    if (lim.error) return fail(res, 403, lim.error);
    let balance = Number(user.balance) || 0;
    if (balance < amount) return fail(res, 402, '余额不足，先充值再来');
    /* 会话：没有就现开一个 —— 转账记录要落在会话里（微信也是这么记的） */
    let chat = directChatBetween(user.id, target.id);
    if (!chat) {
      chat = {
        id: uid('c'), type: 'direct', name: '', avatar: '',
        memberIds: [user.id, target.id], ownerId: user.id, seq: 0, createdAt: now()
      };
      db.chats.push(chat);
      sendTo(target.id, { type: 'chat', action: 'created', chat: chatSummary(chat, target.id) });
    }
    const paidMoney = applyMoney(user, -amount, { reason: '扫码付款', ref: target.id });
    if (paidMoney.error) return fail(res, 402, paidMoney.error);
    balance = paidMoney.balance;
    const note = str(body.note, 40) || (found.kind === 'pay' ? '扫码付款' : '收款码付款');
    const transfer = {
      id: uid('tr'), chatId: chat.id, fromId: user.id, toId: target.id,
      amount: amount, note: note, method: 'balance', status: 'received',
      createdAt: now(), expiresAt: 0, receivedAt: now(), refundedAt: '', messageId: ''
    };
    db.transfers.unshift(transfer);
    if (db.transfers.length > 800) db.transfers.length = 800;
    const sent = deliverMessage(user, chat.id, 'transfer', transferSnapshot(transfer), null);
    if (sent.error) {
      db.transfers = db.transfers.filter((x) => x.id !== transfer.id);
      user.balance = rpRound2(balance + amount);       // 发不出去就把钱还回去
      saveUsers();
      return fail(res, 400, sent.error);
    }
    transfer.messageId = sent.message.id;
    syncTransferMessage(transfer);
    /* 钱当时到对方账上（微信商家收款就是即时到账）：开了经营账户就走经营账户 */
    bizCollect(target, amount, user.nickname || user.username || '好友', user.id, 'paycode', note);
    saveUsers();
    saveTransfers();
    broadcastTransfer(transfer, 'received');
    sendTo(user.id, { type: 'balance', balance: balance });
    /* 付款码是一次性的：用过就作废（微信也是刷一次就换） */
    if (found.kind === 'pay' && found.code) {
      const rec = payCodes.get(found.code);
      if (rec) rec.used = true;
    }
    audit(req, { username: user.username, name: user.nickname, role: '用户本人' },
      '扫码付款', target.username, amount.toFixed(2) + ' 元');
    const payPayload = {
      balance: balance, amount: amount,
      payee: publicUser(target),
      transfer: JSON.parse(transferSnapshot(transfer))
    };
    idemFinish(idem.key, payPayload);
    ok(res, payPayload);
    return;
  }

  if (parts[0] === 'pay' && parts[1] === 'transfer' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const body = await readBody(req);
    /* 幂等：同一笔（同一个 requestId）只处理一次 —— 超时重发、连点都不会扣两次 */
    const idem = idemBegin(user, body, 'transfer');
    if (idem.dup) {
      if (idem.inflight) return fail(res, 409, '这笔正在处理，稍等一秒看余额再操作');
      return ok(res, idem.cached);
    }
    const amount = Math.round((Number(body.amount) || 0) * 100) / 100;
    const useBalance = body.method !== 'card';
    const face = !!body.face;                                   // 「使用面容」= 已通过人脸
    const pwd = String(body.password || '').trim();
    const note = str(body.note, 60);
    if (!(amount > 0)) return fail(res, 422, '转账金额要大于 0');
    if (amount > 200000) return fail(res, 422, '单笔最多 200000');
    const limit = user.transferLimit === undefined ? 20000 : Number(user.transferLimit) || 0;
    if (limit > 0 && amount > limit) return fail(res, 422, '超过单笔转账限额 ¥' + limit.toFixed(2) + '，可在设置里调');
    /* 转账必须过支付密码（和发红包一个规矩） */
    if (payPasswordGate(req, res, user, body, '转账')) return;
    const chat = db.chats.find((c) => c.id === str(body.chatId, 60));
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');

    /* 账户等级额度：超了就提示去「账户升级服务」（微信也是这个提示） */
    const lim = walletLimitCheck(user, amount);
    if (lim.error) return fail(res, 403, lim.error);

    // 不管选的是余额还是银行卡，钱都从余额里扣：用多少扣多少，没余额就付不了
    const charge = applyMoney(user, -amount, { reason: '转账', ref: chat.id });
    if (charge.error) return fail(res, 402, charge.error);
    let balance = charge.balance;
    const peerId = chat.type === 'direct' ? chat.memberIds.filter((id) => id !== user.id)[0] : '';
    // 转账单：钱先挂着，对方点了「收钱」才进他余额；24 小时没人收自动退回
    const transfer = {
      id: uid('tr'),
      chatId: chat.id,
      fromId: user.id,
      toId: peerId || '',
      amount,
      note: note || '',
      method: useBalance ? 'balance' : 'card',
      status: 'pending',
      createdAt: now(),
      expiresAt: Date.now() + TRANSFER_TTL_MS,
      receivedAt: '',
      refundedAt: '',
      messageId: ''
    };
    db.transfers.unshift(transfer);
    if (db.transfers.length > 800) db.transfers.length = 800;
    const sent = deliverMessage(user, chat.id, 'transfer', transferSnapshot(transfer), null);
    if (sent.error) {
      db.transfers = db.transfers.filter((x) => x.id !== transfer.id);
      applyMoney(user, amount, { reason: '转账发不出去退回', ref: transfer.id });   // 发不出去就把钱还回去
      saveUsers();
      return fail(res, 400, sent.error);
    }
    transfer.messageId = sent.message.id;
    syncTransferMessage(transfer);
    saveUsers();
    saveTransfers();
    sendTo(user.id, { type: 'balance', balance: balance });         // 自己余额实时减
    const payload = {
      balance, amount,
      method: useBalance ? 'balance' : 'card',
      deducted: amount,
      transfer: JSON.parse(transferSnapshot(transfer))
    };
    idemFinish(idem.key, payload);
    ok(res, payload);
    return;
  }

  /* 收款：对方点「收钱」，钱才真正进他余额 */
  if (parts[0] === 'transfers' && parts[2] === 'claim' && method === 'POST') {
    const tr = db.transfers.find((x) => x.id === str(parts[1], 60));
    if (!tr) return fail(res, 404, '转账单不存在');
    if (tr.toId !== user.id) return fail(res, 403, '这笔转账不是给你的');
    if (tr.status === 'received') return fail(res, 409, '这笔钱已经收过了');
    if (tr.status === 'refunded') return fail(res, 409, '超过 24 小时没收，钱已退回对方');
    if (tr.expiresAt <= Date.now()) { expireTransfers(); return fail(res, 409, '超过 24 小时没收，钱已退回对方'); }
    tr.status = 'received';
    tr.receivedAt = now();
    /* 收到的钱：开了经营账户且选了「到账经营账户」就进经营账户，否则照旧进零钱；
       两种情况都会记一条收款流水（后台「经营账户查账」看的就是它） */
    const payer = findUser(tr.fromId) || {};
    bizCollect(user, tr.amount, payer.nickname || payer.username || '好友', tr.fromId, 'transfer', tr.note || '');
    saveTransfers();
    sendTo(user.id, { type: 'balance', balance: user.balance });
    broadcastTransfer(tr, 'received');
    ok(res, { balance: user.balance, transfer: JSON.parse(transferSnapshot(tr)) });
    return;
  }

  /* 付款方「提醒对方收款」：真的把提醒推到对方手机上（微信也是这样，
     对方会收到一条提醒），不再是只在自己这边弹个假提示。
     1 分钟内只允许提醒一次，防刷屏。 */
  if (parts[0] === 'transfers' && parts[2] === 'remind' && method === 'POST') {
    const tr = db.transfers.find((x) => x.id === str(parts[1], 60));
    if (!tr) return fail(res, 404, '转账单不存在');
    if (tr.fromId !== user.id) return fail(res, 403, '只有付款方可以提醒对方');
    if (tr.status === 'received') return fail(res, 409, '对方已经收过款了');
    if (tr.status === 'refunded') return fail(res, 409, '这笔转账已经退回了');
    const lastAt = Number(tr.remindedAt) || 0;
    if (Date.now() - lastAt < 60 * 1000) {
      const wait = Math.ceil((60 * 1000 - (Date.now() - lastAt)) / 1000);
      return fail(res, 429, '刚提醒过，' + wait + ' 秒后再提醒一次');
    }
    tr.remindedAt = Date.now();
    saveTransfers();
    const who = user.nickname || user.username || '好友';
    const money = Number(tr.amount || 0).toFixed(2);
    if (tr.toId) {
      sendTo(tr.toId, {
        type: 'transferRemind',
        chatId: tr.chatId,
        transferId: tr.id,
        amount: tr.amount,
        fromName: who,
        announce: who + ' 提醒你确认收款 ¥' + money
      });
    }
    ok(res, { remindedAt: tr.remindedAt });
    return;
  }

  /* 收款方「退还」：收到钱以后把钱原路退给付款方（微信转账详情里收款方那颗按钮）。
     钱从收款方的零钱（或经营账户，看他的到账设置）扣，加回付款方余额。 */
  if (parts[0] === 'transfers' && parts[2] === 'refund' && method === 'POST') {
    const tr = db.transfers.find((x) => x.id === str(parts[1], 60));
    if (!tr) return fail(res, 404, '转账单不存在');
    if (tr.toId !== user.id) return fail(res, 403, '只有收款方可以退还');
    if (tr.status === 'pending') return fail(res, 409, '这笔还没收款，24 小时没领会自动退回');
    if (tr.status === 'refunded') return fail(res, 409, '这笔已经退还过了');
    /* 用户规则：**收款后 5 小时内才能退还**，超过 5 小时就不能退了
       （24 小时那个是"还没收款自动退回"，跟这里的"收了又退"不是一回事）。 */
    const receivedMs = Date.parse(String(tr.receivedAt || ''));
    if (receivedMs && Date.now() - receivedMs > 5 * 60 * 60 * 1000) {
      return fail(res, 409, '收款超过 5 小时，不能再退回了');
    }
    const payer = findUser(tr.fromId);
    if (!payer) return fail(res, 404, '对方账号不在了，联系管理员处理');
    const amount = rpRound2(Number(tr.amount) || 0);
    if (!(amount > 0)) return fail(res, 422, '金额不对，联系管理员查单');

    const acc = bizOf(user.id, false);
    const inBiz = !!(acc.enabled && acc.settings.arrival === 'biz');
    if (inBiz) {
      const a = bizOf(user.id, true);
      if ((Number(a.balance) || 0) < amount) return fail(res, 402, '经营账户余额不够退还');
      const beforeBiz = moneyRound(a.balance);
      a.balance = moneyRound(beforeBiz - amount);
      saveBizAll();
      journalMoney({
        at: new Date().toISOString(), userId: 'biz:' + user.id,
        delta: -moneyRound(amount), before: beforeBiz, after: a.balance,
        reason: '收款方退还（经营账户）', ref: tr.id
      });
    } else {
      const paid = applyMoney(user, -amount, { reason: '收款方退还', ref: tr.id });
      if (paid.error) return fail(res, 402, '零钱不够退还，先充值再退');
    }
    applyMoney(payer, amount, { reason: '收到退还', ref: tr.id });
    saveUsers();
    tr.status = 'refunded';
    tr.refundedAt = now();
    tr.refundedBy = user.id;          // 区分「收款方退还」和「24 小时自动退回」
    saveTransfers();
    bizPush(user.id, {
      kind: 'refund', amount: -amount, fromName: payer.nickname || payer.username || '好友',
      fromId: payer.id, method: 'transfer', note: tr.note || '', settled: !inBiz
    });
    sendTo(user.id, { type: 'balance', balance: Number(user.balance) || 0 });
    sendTo(payer.id, { type: 'balance', balance: Number(payer.balance) || 0 });
    broadcastTransfer(tr, 'refunded');
    ok(res, { balance: Number(user.balance) || 0, transfer: JSON.parse(transferSnapshot(tr)) });
    return;
  }

  /* 发红包（微信那一套）：单聊 1 个；群聊可以设个数，拼手气 / 普通。
     发的时候先把总额从余额里扣掉，抢一个扣一个，24 小时没抢完的把剩下的退回。 */
  if (parts[0] === 'pay' && parts[1] === 'redpacket' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const body = await readBody(req);
    /* 幂等：同一个 requestId 只会发一次红包（重发/连点不会扣两次钱） */
    const idem = idemBegin(user, body, 'redpacket');
    if (idem.dup) {
      if (idem.inflight) return fail(res, 409, '这个红包正在发送，稍等一秒再操作');
      return ok(res, idem.cached);
    }
    const face = !!body.face;
    const pwd = String(body.password || '').trim();
    const note = str(body.note, 50) || '恭喜发财，大吉大利';
    const chat = db.chats.find((c) => c.id === str(body.chatId, 60));
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');

    const isGroup = chat.type === 'group';
    const total = rpRound2(body.amount);
    /* 账户等级额度：发红包也算转出（和微信一样要过额度） */
    const rpLim = walletLimitCheck(user, total);
    if (rpLim.error) return fail(res, 403, rpLim.error);
    /* 单聊只能发 1 个；群聊 1~100 个（微信上限就是 100） */
    let count = isGroup ? Math.round(Number(body.count) || 1) : 1;
    count = Math.max(1, Math.min(100, count));
    const type = (isGroup && String(body.type || '') === 'lucky') ? 'lucky' : 'normal';
    if (!(total > 0)) return fail(res, 422, '红包金额要大于 0');
    /* 上限可配（data/payrules.json 的 redPacketMax）：想和微信一致就写 200。
       微信单个红包上限就是 200 元，我们默认给得宽，按需要压。 */
    const rpMaxOne = payRuleNum('redPacketMax', 200000);
    if (total > rpMaxOne) return fail(res, 422, '单个红包最多 ' + rpMaxOne + ' 元');
    if (total < count * 0.01) return fail(res, 422, '每个红包最少 0.01 元，金额再大一点');
    if (type === 'normal' && count > 1) {
      /* 普通红包：微信要求能平均分，分不尽就提示（避免出现 0.01 的零头） */
      const each = rpRound2(total / count);
      if (Math.abs(each * count - total) > 0.005) {
        return fail(res, 422, '普通红包要能平分：' + count + ' 个 × ' + each.toFixed(2) + ' 元，金额改成 ' + (each * count).toFixed(2) + ' 元');
      }
    }
    /* 发红包必须过支付密码（没设过的先去设，不再允许"直接付"） */
    if (payPasswordGate(req, res, user, body, '发红包')) return;

    let balance = Number(user.balance) || 0;
    if (balance < total) return fail(res, 402, '余额不足，先充值再来');
    const rpPay = applyMoney(user, -total, { reason: '发红包', ref: chat.id + ':' + (body.count || 1) });
    if (rpPay.error) return fail(res, 402, rpPay.error);
    balance = rpPay.balance;

    const peerId = chat.type === 'direct' ? (chat.memberIds.filter((id) => id !== user.id)[0] || '') : '';
    const rp = {
      id: uid('rp'),
      chatId: chat.id,
      fromId: user.id,
      fromName: user.nickname || user.username || '',
      toId: peerId,
      total,
      count,
      type,
      coverId: (rpCoverOf(body.coverId || user.rpCover) || {}).id || '',
      note: note || '',
      status: 'pending',
      claims: [],
      createdAt: now(),
      expiresAt: Date.now() + TRANSFER_TTL_MS,
      refundedAt: '',
      refundAmount: 0,
      expired: false,
      messageId: ''
    };
    if (!Array.isArray(db.redpackets)) db.redpackets = [];
    db.redpackets.unshift(rp);
    if (db.redpackets.length > 800) db.redpackets.length = 800;

    const sent = deliverMessage(user, chat.id, 'redpacket', redpacketSnapshot(rp), null);
    if (sent.error) {
      db.redpackets = db.redpackets.filter((x) => x.id !== rp.id);
      applyMoney(user, total, { reason: '红包发不出去退回', ref: rp.id });   // 发不出去就把钱还回去
      saveUsers();
      return fail(res, 400, sent.error);
    }
    rp.messageId = sent.message.id;
    syncRedPacketMessage(rp);
    saveUsers();
    saveRedPackets();
    sendTo(user.id, { type: 'balance', balance: user.balance });
    const rpPayload = {
      balance: user.balance, amount: total, count, type,
      coverId: rp.coverId,
      redpacket: JSON.parse(redpacketSnapshot(rp))
    };
    idemFinish(idem.key, rpPayload);
    ok(res, rpPayload);
    return;
  }

  /* 红包封面：能选的封面列表 + 我自己选的那张 */
  if (parts[0] === 'redpacket' && parts[1] === 'covers' && method === 'GET') {
    const cfg = readRpCovers();
    ok(res, {
      covers: cfg.covers.filter((c) => c.enabled).map((c) => ({
        id: c.id, name: c.name, image: c.image, thumb: c.thumb, color: c.color
      })),
      defaultId: cfg.defaultId,
      mine: rpCoverOf(user.rpCover).id
    });
    return;
  }

  /* 选一张我自己的红包封面（下次发红包默认用它） */
  if (parts[0] === 'redpacket' && parts[1] === 'cover' && method === 'POST') {
    const body = await readBody(req);
    const id = str(body.id, 30);
    const cover = readRpCovers().covers.find((c) => c.id === id && c.enabled);
    if (!cover) return fail(res, 404, '没有这张封面，刷新一下再试');
    user.rpCover = cover.id;
    saveUsers();
    ok(res, { coverId: cover.id, name: cover.name });
    return;
  }

  /* ---------------- 成长（QQ 等级那套）----------------
     客户端在 App 里每 60 秒上报一次「这次用了多久」，服务端按天结算活跃天。
     等级不看时长小数，只看累计活跃天：D = L² + 4L。 */
  if (parts[0] === 'growth' && parts[1] === 'ping' && method === 'POST') {
    const body = await readBody(req);
    if (blockedByRealName(res, user)) return;      // 被限制的账号不让刷等级
    ok(res, { growth: pingActivity(user.id, body.seconds) });
    return;
  }
  if (parts[0] === 'growth' && parts[1] === 'me' && method === 'GET') {
    ok(res, { growth: growthSnapshot(user.id) });
    return;
  }

  /* ---------------- 会员（我们自己那套）----------------
     会员中心要的东西一次给全：档位 + 价格 + 权益文案 + 我的状态 + 开通记录。
     开通走零钱扣款（要支付密码）；后台生成的兑换码也能开。 */
  if (parts[0] === 'membership' && method === 'GET') {
    const cfg = memberCfg();
    ok(res, {
      membership: {
        enabled: cfg.enabled,
        title: cfg.title,
        sub: cfg.sub,
        tiers: cfg.tiers,
        benefits: cfg.benefits,
        me: memberOf(user.id),
        balance: Math.round((Number(user.balance) || 0) * 100) / 100,
        history: memberHistoryOf(user.id).slice(-20).reverse()
      }
    });
    return;
  }
  if (parts[0] === 'membership' && parts[1] === 'open' && method === 'POST') {
    const body = await readBody(req);
    const cfg = memberCfg();
    if (!cfg.enabled) return fail(res, 422, '会员功能还没开');
    const tier = tierOf(str(body.tierId, 20));
    if (!tier) return fail(res, 404, '没有这个档位');
    const months = Math.max(1, Math.min(36, Math.floor(Number(body.months) || 1)));
    const price = memberPrice(tier, months);
    if (!hasPayPassword(user)) return fail(res, 422, '先设一个支付密码（我 → 设置 → 支付密码）');
    if (!verifyPayPassword(user, String(body.payPassword || '').trim())) {
      return fail(res, 403, '支付密码不对');
    }
    if ((Number(user.balance) || 0) + 1e-9 < price) return fail(res, 402, '零钱不够，先去钱包充值');
    user.balance = Math.round(((Number(user.balance) || 0) - price) * 100) / 100;
    const me = setMember(user.id, tier.id, monthsToDays(months), 'open', price, months);
    saveUsers();
    audit(req, { username: user.username || '', name: user.nickname || '', role: 'user' },
      '开通会员', user.username || user.id, tier.name + ' ' + months + ' 个月 ' + price + ' 元');
    ok(res, { membership: me, balance: user.balance, paid: price });
    return;
  }
  if (parts[0] === 'membership' && parts[1] === 'auto' && method === 'POST') {
    const body = await readBody(req);
    const dbm = readMemberDb();
    const rec = dbm.users[user.id];
    if (!rec || !rec.tier) return fail(res, 422, '还不是会员');
    rec.autoRenew = body.on !== false;
    saveMemberDb();
    ok(res, { membership: memberOf(user.id) });
    return;
  }
  if (parts[0] === 'membership' && parts[1] === 'redeem' && method === 'POST') {
    const body = await readBody(req);
    const code = String(body.code || '').trim().toUpperCase().slice(0, 32);
    if (!code) return fail(res, 422, '请输入兑换码');
    const dbm = readMemberDb();
    const row = dbm.codes.find((c) => c.code === code);
    if (!row) return fail(res, 404, '兑换码不对');
    if (row.usedBy) return fail(res, 409, '这张兑换码已经用过了');
    const t = tierOf(row.tierId);
    if (!t) return fail(res, 404, '兑换码对应的档位没了');
    row.usedBy = user.id;
    row.usedAt = now();
    const me = setMember(user.id, t.id, row.days, 'redeem ' + code, 0, 0);
    saveMemberDb();
    ok(res, { membership: me, tier: t.name, days: row.days });
    return;
  }
  if (parts[0] === 'growth' && parts[1] === 'rank' && method === 'GET') {
    const mine = growthSnapshot(user.id);
    ok(res, {
      rank: qqRanking(query.get('limit') || 50),
      me: { id: user.id, name: user.nickname || user.username || '', avatar: user.avatar || '',
        total: mine.total, level: mine.level, icons: mine.icons }
    });
    return;
  }

  /* 扫一扫 → 翻译：客户端把 OCR 出来的文字发过来，交给后台配的大模型翻译 */
  if (parts[0] === 'scan' && parts[1] === 'translate' && method === 'POST') {
    const body = await readBody(req);
    const text = str(body.text, 3000);
    if (!text) return fail(res, 422, '没有识别到文字');
    const to = str(body.to, 12) || '中文';
    try {
      const out = await llmChat([
        { role: 'system', content: '你是翻译引擎。只输出译文本身：不要解释、不要加引号、不要附原文。' },
        { role: 'user', content: '把下面这段翻译成' + to
          + '（如果它本来就是' + to + '，就翻译成英文）：\n' + text }
      ], Object.assign({}, readAiCfg(), { temperature: 0.3, maxTokens: 1200 }));
      ok(res, { text: out });
    } catch (e) {
      return fail(res, 503, '翻译服务没配好：' + String((e && e.message) || e).slice(0, 80));
    }
    return;
  }

  /* 红包详情：谁抢了多少、手气最佳是谁（微信点开红包卡片看的那一页） */
  if (parts[0] === 'redpackets' && parts.length === 2 && parts[1] !== 'mine' && method === 'GET') {
    const rp = (db.redpackets || []).find((x) => x.id === str(parts[1], 60));
    if (!rp) return fail(res, 404, '红包不存在');
    const chat = db.chats.find((c) => c.id === rp.chatId);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (rp.status === 'pending' && rp.expiresAt <= Date.now()) expireRedPackets();
    const best = rpBest(rp);
    const myClaim = rpClaims(rp).find((c) => c.userId === user.id) || null;
    ok(res, {
      redpacket: Object.assign(JSON.parse(redpacketSnapshot(rp)), {
        fromAvatar: (findUser(rp.fromId) || {}).avatar || '',
        claimedTotal: rpClaimed(rp),
        leftAmount: rpLeftAmount(rp),
        leftCount: rpLeftCount(rp),
        mine: myClaim ? { amount: myClaim.amount, at: myClaim.at } : null,
        bestUserId: best ? best.userId : '',
        bestAmount: best ? best.amount : 0,
        claims: rpClaims(rp).map((c) => {
          const u = findUser(c.userId) || {};
          return {
            userId: c.userId,
            name: c.name || u.nickname || u.username || '好友',
            avatar: u.avatar || '',
            amount: c.amount,
            at: c.at,
            fromId: rp.fromId,
            fromName: rp.fromName || (findUser(rp.fromId) || {}).nickname || ''
          };
        })
      })
    });
    return;
  }

  /* 我收到的 / 我发出的红包（微信「红包记录」） */
  if (parts[0] === 'redpackets' && parts[1] === 'mine' && method === 'GET') {
    const list = (db.redpackets || []).filter((r) =>
      r.fromId === user.id || rpClaims(r).some((c) => c.userId === user.id));
    const rows = list.slice(0, 100).map((r) => {
      const mine = rpClaims(r).find((c) => c.userId === user.id) || null;
      const u = findUser(r.fromId) || {};
      return {
        id: r.id,
        chatId: r.chatId,
        direction: r.fromId === user.id ? 'out' : 'in',
        total: r.total,
        count: r.count,
        type: r.type,
        note: r.note || '',
        status: r.status,
        expired: !!r.expired,
        claimedCount: rpClaims(r).length,
        fromName: r.fromName || u.nickname || '',
        fromAvatar: u.avatar || '',
        mineAmount: mine ? mine.amount : 0,
        createdAt: r.createdAt,
        expiresAt: r.expiresAt
      };
    });
    ok(res, { redpackets: rows });
    return;
  }

  /* 拆红包：点「开」才真正进余额。发红包的人不能抢自己的，同一个人只能抢一次 */
  if (parts[0] === 'redpackets' && parts[2] === 'claim' && method === 'POST') {
    const rp = (db.redpackets || []).find((x) => x.id === str(parts[1], 60));
    if (!rp) return fail(res, 404, '红包不存在');
    const chat = db.chats.find((c) => c.id === rp.chatId);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (rp.fromId === user.id) return fail(res, 403, '不能抢自己发的红包');
    if (rpClaims(rp).some((c) => c.userId === user.id)) return fail(res, 409, '这个红包你已经抢过了');
    if (rp.expiresAt <= Date.now()) {
      expireRedPackets();
      return fail(res, 409, '红包超过 24 小时了，没抢到的钱已经退回给对方');
    }
    if (rp.status !== 'pending') return fail(res, 409, '手慢了，红包已经被抢完了');
    const amount = drawRedPacketAmount(rp);
    if (!(amount > 0)) { expireRedPackets(); return fail(res, 409, '红包已经过期了'); }
    if (!Array.isArray(rp.claims)) rp.claims = [];
    rp.claims.push({
      userId: user.id,
      name: user.nickname || user.username || '',
      amount,
      at: now()
    });
    /* 抢到的红包钱：和收转账一样走「收款流水」（开了经营账户就进经营账户余额） */
    const rpSender = findUser(rp.fromId) || {};
    bizCollect(user, amount, rpSender.nickname || rpSender.username || '好友', rp.fromId, 'redpacket', rp.note || '红包');
    if (rp.claims.length >= (Number(rp.count) || 1)) rp.status = 'done';
    saveRedPackets();
    broadcastRedPacket(rp, 'claim');
    /* 群聊里抢红包会多一条灰条（微信就是这样），单聊不刷屏 */
    if (chat.type === 'group') {
      const sys = pushSystemMessage(chat, (user.nickname || user.username || '好友') + ' 领取了你的红包');
      chat.memberIds.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
      saveChats();
    }
    const best = rpBest(rp);
    ok(res, {
      balance: user.balance,
      amount,
      redpacket: JSON.parse(redpacketSnapshot(rp)),
      bestUserId: best ? best.userId : '',
      leftCount: rpLeftCount(rp)
    });
    return;
  }

  /* 余额充值（手机端自助）：POST { amount } */
  /* ============================================================
     零钱：银行卡 / 充值 / 提现（微信「我 → 服务 → 钱包 → 零钱」那一套）
     · 银行卡只存「银行名 + 末四位」，完整卡号不留在服务器上
     · 充值：银行卡 → 零钱（我们自己记账，后台 allowRecharge 开关控制）
     · 提现：零钱 → 银行卡，手续费 0.1%（最低 0.1 元），要支付密码
     · 充值 / 提现 / 提现手续费 都会进账单
     ============================================================ */
  if (parts[0] === 'wallet' && parts[1] === 'banks' && method === 'GET') {
    if (blockedByRealName(res, user)) return;
    ok(res, { banks: userBanks(user) });
    return;
  }

  if (parts[0] === 'wallet' && parts[1] === 'banks' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const body = await readBody(req);
    const cardNo = String(body.cardNo || '').replace(/\D/g, '');
    if (cardNo.length < 12 || cardNo.length > 19) return fail(res, 422, '卡号不对（12~19 位数字）');
    const list = userBanks(user);
    if (list.length >= 10) return fail(res, 422, '最多绑 10 张卡');
    const row = {
      id: uid('bk'),
      bank: str(body.bank, 20) || '银行卡',
      tail: cardNo.slice(-4),
      holder: str(body.holder, 20),
      isDefault: list.length === 0,
      addedAt: now()
    };
    list.push(row);
    saveUsers();
    recordSecurity(user.id, req, 'bank-add', { note: row.bank + ' 尾号' + row.tail });
    ok(res, { bank: row, banks: list });
    return;
  }

  if (parts[0] === 'wallet' && parts[1] === 'banks' && parts[2] === 'remove' && method === 'POST') {
    const body = await readBody(req);
    const id = str(body.id, 40);
    const list = userBanks(user);
    const hit = list.find((b) => b.id === id);
    if (!hit) return fail(res, 404, '这张卡不在了');
    user.banks = list.filter((b) => b.id !== id);
    if (hit.isDefault && user.banks.length) user.banks[0].isDefault = true;
    saveUsers();
    ok(res, { banks: user.banks });
    return;
  }

  /* 充值：银行卡 → 零钱 */
  if (parts[0] === 'wallet' && parts[1] === 'recharge' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const rules = readWalletRules();
    if (!rules.allowRecharge || !secCfg().allowRecharge) {
      return fail(res, 403, '充值暂未开放，请让管理员在后台打开「允许用户自助充值」');
    }
    const body = await readBody(req);
    const amount = Math.round((Number(body.amount) || 0) * 100) / 100;
    if (!(amount > 0)) return fail(res, 422, '充值金额要大于 0');
    if (amount < 0.01) return fail(res, 422, '充值金额太小');
    if (amount > rules.rechargeMax) return fail(res, 422, '单次充值最多 ¥' + rules.rechargeMax);
    const list = userBanks(user);
    const bank = list.find((b) => b.id === str(body.bankId, 40)) || list.find((b) => b.isDefault) || list[0] || null;
    const before = Number(user.balance) || 0;
    applyMoney(user, amount, { reason: '充值到零钱', ref: bank ? bank.tail : '' });
    saveUsers();
    const op = pushWalletOp({
      id: uid('wop'), userId: user.id, kind: 'recharge', amount,
      bankText: bank ? (bank.bank + '（' + bank.tail + '）') : '银行卡',
      status: 'done', createdAt: now(), doneAt: now()
    });
    recordSecurity(user.id, req, 'recharge', { note: '充值 ' + amount });
    sendTo(user.id, { type: 'balance', balance: user.balance });
    ok(res, { recharged: amount, balanceBefore: before, balance: user.balance, op });
    return;
  }

  /* 提现：零钱 → 银行卡（微信：每笔 0.1%，最低 0.1 元，2 小时内到账） */
  if (parts[0] === 'wallet' && parts[1] === 'withdraw' && method === 'POST') {
    if (blockedByRealName(res, user)) return;
    const rules = readWalletRules();
    const body = await readBody(req);
    const amount = Math.round((Number(body.amount) || 0) * 100) / 100;
    if (!(amount > 0)) return fail(res, 422, '提现金额要大于 0');
    if (amount < rules.withdrawMin) return fail(res, 422, '提现最少 ¥' + rules.withdrawMin.toFixed(2));
    if (amount > rules.withdrawMax) return fail(res, 422, '单笔提现最多 ¥' + rules.withdrawMax);
    /* 提现也算转出额度（微信也是一样按账户等级限额） */
    const wdLim = walletLimitCheck(user, amount);
    if (wdLim.error) return fail(res, 403, wdLim.error);
    const face = !!body.face;
    const pwd = String(body.password || '').trim();
    /* 提现也要支付密码 */
    if (payPasswordGate(req, res, user, body, '提现')) return;
    const list = userBanks(user);
    const bank = list.find((b) => b.id === str(body.bankId, 40)) || list.find((b) => b.isDefault) || list[0] || null;
    if (!bank) return fail(res, 422, '先加一张银行卡');
    const fee = Math.max(rules.feeMin, Math.round(amount * rules.feeRate * 100) / 100);
    const before = Number(user.balance) || 0;
    if (before < amount + fee) {
      return fail(res, 402, '零钱不够：要提 ¥' + amount.toFixed(2) + '，手续费 ¥' + fee.toFixed(2)
        + '，当前零钱 ¥' + before.toFixed(2));
    }
    const wd = applyMoney(user, -(amount + fee), { reason: '提现（含手续费 ¥' + fee.toFixed(2) + '）', ref: bank.tail });
    if (wd.error) return fail(res, 402, wd.error);
    saveUsers();
    const op = pushWalletOp({
      id: uid('wop'), userId: user.id, kind: 'withdraw', amount, fee,
      bankText: bank.bank + '（' + bank.tail + '）', bankId: bank.id,
      /* 后台关了「提现审核」就直接算到账（微信也是即时处理），开着就要等后台点 */
      status: rules.withdrawReview ? 'pending' : 'done',
      createdAt: now(), doneAt: rules.withdrawReview ? '' : now()
    });
    recordSecurity(user.id, req, 'withdraw', { note: '提现 ' + amount + ' 手续费 ' + fee });
    sendTo(user.id, { type: 'balance', balance: user.balance });
    ok(res, {
      amount, fee, balance: user.balance, status: 'pending',
      bankText: op.bankText, expect: rules.withdrawReview ? '已提交，等待管理员审核' : '预计 2 小时内到账'
    });
    return;
  }

  /* 提现记录 */
  if (parts[0] === 'wallet' && parts[1] === 'withdraws' && method === 'GET') {
    if (blockedByRealName(res, user)) return;
    const mine = readWalletOps().ops.filter((o) => o.userId === user.id).slice(0, 100);
    const rules = readWalletRules();
    ok(res, { ops: mine, rules: { feeRate: rules.feeRate, feeMin: rules.feeMin, withdrawMin: rules.withdrawMin, withdrawMax: rules.withdrawMax, allowRecharge: !!rules.allowRecharge, rechargeMax: rules.rechargeMax, note: rules.note } });
    return;
  }

  if (parts[0] === 'me' && parts[1] === 'recharge' && method === 'POST') {
    /* 安全：以前任何登录用户都能自己给自己加钱（等于自己印钱）。
       现在默认关闭，要充值走后台（后台 → 用户 → 充值），
       确实想让用户自己充，再把 data/security.json 里的 allowRecharge 改成 1。 */
    if (!secCfg().allowRecharge) {
      strikeIp(clientInfo(req).ip, '用户自助充值');
      return fail(res, 403, '自助充值已关闭，请让管理员在后台给你充值');
    }
    const body = await readBody(req);
    const amount = Math.round((Number(body.amount) || 0) * 100) / 100;
    if (!(amount > 0)) return fail(res, 422, '充值金额要大于 0');
    if (amount > 1000000) return fail(res, 422, '单次充值不能超过 1000000');
    const before = Number(user.balance) || 0;
    applyMoney(user, amount, { reason: '自助充值' });
    saveUsers();
    recordSecurity(user.id, req, 'recharge', { note: '充值 ' + amount });
    ok(res, { recharged: amount, balanceBefore: before, balance: user.balance });
    return;
  }

  /* 收藏：GET 列表 / POST 加一条 / DELETE 删一条 */
  if (parts[0] === 'favorites' && method === 'GET') {
    /* 置顶的排最前面，其余按时间倒序（微信收藏就是这样；pinned 是 2026-10-12 加的） */
    const list = (Array.isArray(user.favorites) ? user.favorites.slice() : [])
      .sort((a, b) => ((b.pinned ? 1 : 0) - (a.pinned ? 1 : 0))
        || String(b.at || '').localeCompare(String(a.at || '')));
    ok(res, { favorites: list });
    return;
  }
  if (parts[0] === 'favorites' && method === 'POST') {
    const body = await readBody(req);
    const kind = ['text', 'image', 'images', 'transfer'].indexOf(body.kind) >= 0 ? body.kind : 'text';
    /* 单条收藏最多 2 万字：以前能塞 200 万字 × 300 条，一个人就能把数据库撑爆 */
    const content = str(body.content, 20000);
    if (!content) return fail(res, 422, '内容为空，收藏不了');
    if (!Array.isArray(user.favorites)) user.favorites = [];
    if (user.favorites.length >= 300) return fail(res, 429, '收藏夹最多 300 条，先删几条');
    if (!Array.isArray(user.favorites)) user.favorites = [];
    const fav = {
      id: uid('fav'),
      kind,
      content,
      title: str(body.title, 60),
      from: str(body.from, 40),
      at: now()
    };
    user.favorites.unshift(fav);
    if (user.favorites.length > 300) user.favorites.length = 300;
    saveUsers();
    ok(res, { favorite: fav, count: user.favorites.length });
    return;
  }
  /* 收藏：改一条（编辑正文 / 改标题 / 置顶）—— App 里笔记的「编辑」「置顶」用它，
     编辑后 id 和位置都不变（以前是删旧加新，会跳到最前面） */
  if (parts[0] === 'favorites' && parts.length === 2 && method === 'PATCH') {
    const id = str(parts[1], 40);
    const body = await readBody(req);
    if (!Array.isArray(user.favorites)) user.favorites = [];
    const one = user.favorites.find((f) => f.id === id);
    if (!one) return fail(res, 404, '没有这条收藏');
    if (body.content !== undefined) {
      const c = str(body.content, 20000);
      if (!c) return fail(res, 422, '内容不能为空');
      one.content = c;
    }
    if (body.title !== undefined) one.title = str(body.title, 60);
    if (body.pinned !== undefined) one.pinned = !!body.pinned;
    one.updatedAt = now();
    saveUsers();
    ok(res, { favorite: one });
    return;
  }
  if (parts[0] === 'favorites' && parts.length === 2 && method === 'DELETE') {
    const id = str(parts[1], 40);
    if (!Array.isArray(user.favorites)) user.favorites = [];
    const before = user.favorites.length;
    user.favorites = user.favorites.filter((f) => f.id !== id);
    saveUsers();
    ok(res, { deleted: before !== user.favorites.length });
    return;
  }

  /* 支付密码：GET 看有没有设置 / POST 设置或修改 / POST verify 校验（转账确认用） */
  /* 「我的文件」（我们自己的文件选择页用它，不走苹果那个文件 App）：
     把这个账号在各会话里发过 / 收到过的文件按时间倒序列出来（同一个文件只列一次）。
     管理里把 filePickerSystem 打开时，App 才回去用苹果的文件 App。 */
  if (parts[0] === 'files' && parts[1] === 'mine' && method === 'GET') {
    const limit = Math.min(300, Math.max(1, Number(query.get('limit')) || 120));
    const out = [];
    const seen = {};
    const myChats = db.chats.filter((c) => Array.isArray(c.memberIds) && c.memberIds.includes(user.id));
    /* 新的会话排前面：最近发过的文件一定在最上面 */
    myChats.sort((a, b) => String(b.lastAt || b.createdAt || '').localeCompare(String(a.lastAt || a.createdAt || '')));
    for (let ci = 0; ci < myChats.length && out.length < limit; ci += 1) {
      const c = myChats[ci];
      const list = loadMessages(c.id);
      for (let i = list.length - 1; i >= 0 && out.length < limit; i -= 1) {
        const m = list[i];
        if (!m || m.kind !== 'file' || m.recalled) continue;
        let o = null;
        try { o = JSON.parse(String(m.content || '')); } catch (e) { o = null; }
        if (!o || !o.url) continue;
        const url = String(o.url);
        if (seen[url]) continue;
        seen[url] = 1;
        let title = '';
        try { title = chatSummary(c, user.id, null).name || ''; } catch (e) { title = c.name || ''; }
        out.push({
          id: m.id,
          url: url,
          name: String(o.name || '文件').slice(0, 120),
          bytes: Math.max(0, Number(o.bytes) || 0),
          at: m.createdAt || '',
          chatId: c.id,
          chatName: title,
          mine: m.senderId === user.id
        });
      }
    }
    ok(res, { files: out });
    return;
  }
  if (parts[0] === 'me' && parts[1] === 'paypassword') {
    if (parts[2] === 'verify' && method === 'POST') {
      if (!hasPayPassword(user)) return fail(res, 409, '还没有设置支付密码');
      const body = await readBody(req);
      const pwd = String(body.password || '').trim();
      if (!verifyPayPassword(user, pwd)) {
        recordSecurity(user.id, req, 'pay-password-fail', { note: '支付密码输错' });
        return fail(res, 422, '支付密码不正确');
      }
      ok(res, { verified: true });
      return;
    }
    if (method === 'GET') {
      ok(res, { has: hasPayPassword(user), updatedAt: user.payPasswordAt || '' });
      return;
    }
    if (method === 'POST') {
      const body = await readBody(req);
      const next = String(body.password || '').trim();
      const current = String(body.current || '').trim();
      if (!/^\d{6}$/.test(next)) return fail(res, 422, '支付密码要 6 位数字');
      if (hasPayPassword(user)) {
        if (!verifyPayPassword(user, current)) return fail(res, 401, '原支付密码不正确');
        if (current === next) return fail(res, 422, '新支付密码不能和原来的相同');
      }
      const salt = crypto.randomBytes(16).toString('hex');
      user.paySalt = salt;
      user.payPasswordHash = hashPassword(next, salt);
      user.payPasswordAt = now();
      saveUsers();
      recordSecurity(user.id, req, 'pay-password');
      ok(res, { has: true, updatedAt: user.payPasswordAt });
      return;
    }
  }

  /* 只认 /api/me 本身：/api/me/bankcards 这种子路径要用自己的分支 */
  if (parts[0] === 'me' && parts.length === 1 && method === 'GET') {
    ok(res, {
      user: Object.assign(publicUser(user), {
        phone: user.phone || '',
    alipay: user.alipay || '',
    alipayQr: user.alipayQr || '',
        phoneUpdatedAt: user.phoneUpdatedAt || '',
        balance: Number(user.balance) || 0,                       // 自己的零钱余额（别人看不到）
        transferLimit: user.transferLimit === undefined ? 20000 : Number(user.transferLimit) || 0
      }),
      online: onlineUserIds()
    });
    return;
  }

  if (parts[0] === 'me' && parts[1] === 'status' && method === 'POST') {
    const body = await readBody(req);
    const st = str(body.status, 12);
    const allowed = ['online', 'busy', 'away', 'invisible'];
    if (!allowed.includes(st)) return fail(res, 422, '不支持的在线状态');
    user.status = st;
    saveUsers();
    // 通知好友（隐身在别人眼里就是离线）
    friendIds(user.id).forEach((fid) => sendTo(fid, { type: 'presence', userId: user.id, online: true, status: visibleStatus(user.id) }));
    ok(res, { status: st });
    return;
  }

  if (parts[0] === 'me' && parts.length === 1 && method === 'PATCH') {
    const body = await readBody(req);
    if (body.nickname !== undefined) {
      const nn = str(body.nickname, 24);
      if (nn && nn !== user.nickname) {
        const bad = checkNickname(nn);
        if (bad) return fail(res, 422, bad);
      }
      user.nickname = nn || user.nickname;
    }
    if (body.bio !== undefined) user.bio = str(body.bio, 60);
    if (body.region !== undefined) user.region = str(body.region, 40);
    if (body.gender !== undefined) user.gender = normalizeGender(body.gender);
    /* 生日：对应功能清单里的「生日」（个人资料里能改） */
    if (body.birthday !== undefined) {
      const b = str(body.birthday, 20);
      user.birthday = /^\d{4}-\d{2}-\d{2}$/.test(b) ? b : '';
    }
    /* 头像/封面/聊天背景存的都是 /uploads 路径或短网址，2 千字符足够；
       以前允许 30 万字符，一个人就能把 users.json 撑到几百 MB。 */
    if (body.avatar !== undefined) {
      const v = safeImageRef(str(body.avatar, 2000));
      if (v === null) return fail(res, 422, '头像只能用 App 上传的图片');
      user.avatar = v;
    }
    if (body.alipay !== undefined) user.alipay = str(body.alipay, 60).replace(/\s/g, '');
    if (body.alipayQr !== undefined) {
      const v = safeImageRef(str(body.alipayQr, 2000));
      if (v === null) return fail(res, 422, '收款码只能用 App 上传的图片');
      user.alipayQr = v;
    }
    if (body.phone !== undefined) {
      const next = str(body.phone, 20).replace(/[^0-9+]/g, '');
      const pure = next.replace(/^\+?86/, '');
      if (!/^1[3-9]\d{9}$/.test(pure) && !/^\d{6,20}$/.test(pure)) return fail(res, 422, '手机号格式不对，要 11 位手机号');
      const YEAR_MS = 365 * 24 * 60 * 60 * 1000;
      const last = user.phoneUpdatedAt ? new Date(user.phoneUpdatedAt).getTime() : 0;
      if (last && Date.now() - last < YEAR_MS) {
        const can = new Date(last + YEAR_MS);
        return fail(res, 429, '手机号一年只能改一次，下次可改：' + can.getFullYear() + '年' + (can.getMonth() + 1) + '月' + can.getDate() + '日');
      }
      if (pure !== (user.phone || '')) {
        user.phone = pure;
        user.phoneUpdatedAt = now();
        sysNotice(user.id, '你的账号绑定的手机号已改成 ' + String(pure).replace(/^(\d{3})\d{4}(\d{4})$/, '$1****$2') + '。', '安全提醒', 'security');
      }
    }
    if (body.moodText !== undefined || body.moodIcon !== undefined
        || body.moodLabel !== undefined || body.moodCaption !== undefined) {
      /* 微信那套：状态 24 小时自动过期；「说点什么」最多 30 字；选完记一下时间。
         状态名（moodLabel，后台配的「摸鱼」这种）和自定义文案（moodCaption）分开存，
         moodText 留「拿来展示的那一句」给所有页面用（有文案用文案，没文案用状态名）。 */
      const label = str(body.moodLabel !== undefined ? body.moodLabel : body.moodText, 20);
      const caption = str(body.moodCaption, 30);
      user.moodLabel = label;
      user.moodCaption = caption;
      user.moodText = caption || label;
      user.moodIcon = str(body.moodIcon, 8);
      if (user.moodText || user.moodIcon) {
        /* 换了状态名/图标才重新计时（24 小时）；只改「说点什么」不动到期时间 */
        const key = (user.moodIcon || '') + '|' + label;
        if (user.moodKey !== key) {
          user.moodKey = key;
          user.moodAt = now();
          user.moodExpiresAt = Date.now() + 24 * 60 * 60 * 1000;
          user.moodViews = [];
        } else if (!Number(user.moodExpiresAt)) {
          user.moodExpiresAt = Date.now() + 24 * 60 * 60 * 1000;
        }
      } else {
        user.moodAt = '';
        user.moodExpiresAt = 0;
        user.moodViews = [];
        user.moodKey = '';
      }
      if (body.moodColor !== undefined) {
        const mc = str(body.moodColor, 9);
        user.moodColor = /^#[0-9a-f]{6}$/i.test(mc) ? mc : '';
      }
      if (body.moodColor2 !== undefined) {
        const mc2 = str(body.moodColor2, 9);
        user.moodColor2 = /^#[0-9a-f]{6}$/i.test(mc2) ? mc2 : '';
      }
      if (!user.moodText) user.moodColor = '';
      if (!user.moodText) user.moodColor2 = '';
    }
    /* 拍一拍后缀（微信：我 → 个人资料 → 拍一拍）。别人拍我时显示成
       「XXX 拍了拍我的＿＿」，最多 10 个字；留空就是默认的「拍了拍我」。 */
    if (body.patText !== undefined) {
      user.patText = str(body.patText, 12);
    }
    if (body.momentCover !== undefined) {
      const v = safeImageRef(str(body.momentCover, 2000));
      if (v === null) return fail(res, 422, '朋友圈封面只能用 App 上传的图片');
      user.momentCover = v;
    }
    if (body.momentCoverPos !== undefined) {
      const p = Number(body.momentCoverPos);
      user.momentCoverPos = isFinite(p) ? Math.min(100, Math.max(0, Math.round(p))) : 50;
    }
    if (body.chatBackground !== undefined) {
      const v = safeImageRef(str(body.chatBackground, 2000));
      if (v === null) return fail(res, 422, '聊天背景只能用 App 上传的图片');
      user.chatBackground = v === 'auto' ? 'auto' : v;
    }
    saveUsers();
    // 改了资料：好友那边和自己在别的设备上都能立刻看到新头像 / 新名字
    friendIds(user.id).forEach((fid) => sendTo(fid, { type: 'profile', user: publicUser(user) }));
    sendTo(user.id, { type: 'profile', user: publicUser(user) });
    /* 换了头像：把 TA 所在的群头像（九宫格）重拼一遍，否则群里还是旧头像 */
    if (body.avatar !== undefined) {
      db.chats.filter((c) => c.type === 'group' && (c.memberIds || []).indexOf(user.id) >= 0)
        .forEach((c) => { if (refreshGroupAvatar(c)) { saveChats(); } });
    }
    ok(res, { user: Object.assign(publicUser(user), { phone: user.phone || '', phoneUpdatedAt: user.phoneUpdatedAt || '' }) });
    return;
  }

  // 单个用户资料（微信名片用）
  // 安全中心：登录记录 / 安全评分
  // 修改密码（会踢掉其他设备）
  if (parts[0] === 'me' && parts[1] === 'password' && method === 'POST') {
    const body = await readBody(req);
    const curPwd = String(body.currentPassword || '');
    const nextPwd = String(body.newPassword || '');
    if (!verifyPassword(user, curPwd)) return fail(res, 401, '当前密码不正确');
    if (nextPwd.length < 6) return fail(res, 422, '新密码至少 6 位');
    if (nextPwd === curPwd) return fail(res, 422, '新密码不能和当前密码一样');
    const salt = crypto.randomBytes(16).toString('hex');
    user.salt = salt;
    user.passwordHash = hashPassword(nextPwd, salt);
    sysNotice(user.id, '你的账号密码刚刚被修改了。如果是你改的，忽略这条；不是的话请立刻重新登录并改密码。', '安全提醒', 'security');
    user.passwordUpdatedAt = now();
    user.tokenVersion = (user.tokenVersion || 0) + 1;
    saveUsers();
    recordSecurity(user.id, req, 'password');
    ok(res, { updated: true },
      { 'Set-Cookie': sessionCookie(signToken(user.id, req), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  /* 银行卡：列表 / 绑定 / 解绑（对应功能清单里的「银行卡 / 绑定银行卡」） */
  /* 隐私设置：读 / 改（没设过就是默认值） */
  if (parts[0] === 'me' && parts[1] === 'privacy' && method === 'GET') {
    ok(res, { privacy: userPrivacy(user), notify: userNotify(user) });
    return;
  }
  if (parts[0] === 'me' && parts[1] === 'privacy' && method === 'PATCH') {
    const body = await readBody(req);
    const next = userPrivacy(user);
    ['needVerify', 'strangerMoments', 'addByWx', 'addByPhone', 'addByGroup', 'addByQR'].forEach((k) => {
      if (body[k] !== undefined) next[k] = !!body[k];
    });
    /* 朋友圈可见范围：只认这三个值（最近三天 / 最近半年 / 全部） */
    if (body.momentsRange !== undefined) {
      const v = String(body.momentsRange || '').trim();
      next.momentsRange = (v === '3d' || v === '6m') ? v : 'all';
    }
    user.privacy = next;
    saveUsers();
    ok(res, { privacy: next });
    return;
  }

  /* 消息通知设置：开不开、声音、振动、显示详情、免打扰时段 */
  if (parts[0] === 'me' && parts[1] === 'notify' && method === 'PATCH') {
    const body = await readBody(req);
    const next = userNotify(user);
    ['on', 'sound', 'vibrate', 'showDetail'].forEach((k) => {
      if (body[k] !== undefined) next[k] = !!body[k];
    });
    ['muteStart', 'muteEnd'].forEach((k) => {
      if (body[k] !== undefined) {
        const v = str(body[k], 5);
        next[k] = /^\d{2}:\d{2}$/.test(v) ? v : '';
      }
    });
    user.notify = next;
    saveUsers();
    ok(res, { notify: next });
    return;
  }

  if (parts[0] === 'me' && parts[1] === 'bankcards' && method === 'GET') {
    ok(res, { cards: (user.bankCards || []).map(maskBankCard) });
    return;
  }
  /* 绑卡时能选的银行（名字 + 品牌色）：App 和网页共用一份，后台不用配 */
  if (parts[0] === 'banks' && method === 'GET') {
    ok(res, { banks: BANK_LIST });
    return;
  }
  if (parts[0] === 'me' && parts[1] === 'bankcards' && method === 'POST') {
    const body2 = await readBody(req);
    let bank = str(body2.bank, 20);
    const number = String(body2.number || '').replace(/\s/g, '');
    const holder = str(body2.holder, 20);
    const idCard = str(body2.idCard, 20);
    const phone = String(body2.phone || '').replace(/\D/g, '');
    let cardType = String(body2.type || '').trim();
    if (!/^\d{16,19}$/.test(number)) return fail(res, 422, '卡号要 16~19 位数字');
    /* 微信那套：先按卡号认银行，认不出来才让用户自己选 */
    const guess = guessBankByCardNo(number);
    if (!bank) bank = guess.name;
    if (!bank) return fail(res, 422, '这张卡没认出来，自己选一下银行');
    if (!cardType) cardType = /^(62|62[0-9])/.test(number) && /^(4|5)/.test(number.slice(1)) ? '储蓄卡' : '储蓄卡';
    cardType = (cardType === '信用卡') ? '信用卡' : '储蓄卡';
    if (!holder) return fail(res, 422, '请填写持卡人姓名');
    const cards = Array.isArray(user.bankCards) ? user.bankCards.slice() : [];
    if (cards.length >= 10) return fail(res, 422, '最多绑定 10 张银行卡');
    const tail = number.slice(-4);
    if (cards.some((c) => c.tail === tail && c.bank === bank)) return fail(res, 409, '这张卡已经绑过了');
    /* 微信要求实名一致：填了身份证就跟已实名的姓名对一下 */
    if (user.realName && holder && user.realName !== holder) {
      return fail(res, 422, '持卡人要和实名信息一致（实名是「' + user.realName + '」），只能绑本人的卡');
    }
    const lv = walletLevelInfo(user);
    cards.push({
      id: uid('bc'), bank: bank, number: number, tail: tail, holder: holder,
      type: cardType, idCardTail: idCard ? String(idCard).slice(-4) : '',
      phoneMask: phone.length === 11 ? (phone.slice(0, 3) + '****' + phone.slice(7)) : '',
      noPin: false,                       // 免密支付默认关（微信也是默认关）
      single: lv.single, day: lv.day,     // 这张卡的额度跟着账户等级走
      addedAt: now()
    });
    user.bankCards = cards;
    saveUsers();
    ok(res, { cards: cards.map(maskBankCard) });
    return;
  }
  /* 卡详情里改「免密支付」开关（微信那张卡点进去就这一个开关） */
  if (parts[0] === 'me' && parts[1] === 'bankcards' && parts[2] && method === 'PATCH') {
    const body3 = await readBody(req);
    const id = str(parts[2], 40);
    const card = (user.bankCards || []).find((c) => c.id === id);
    if (!card) return fail(res, 404, '这张卡不在了');
    if (body3.noPin !== undefined) card.noPin = !!body3.noPin;
    saveUsers();
    ok(res, { card: maskBankCard(card) });
    return;
  }
  if (parts[0] === 'me' && parts[1] === 'bankcards' && parts[2] && method === 'DELETE') {
    const id = str(parts[2], 40);
    const card = (user.bankCards || []).find((c) => c.id === id);
    if (!card) return fail(res, 404, '这张卡不在了');
    if (pendingWithdrawToTail(user, card.tail)) {
      return fail(res, 422, '这张卡上还有正在提现的钱，等到账后再解绑');
    }
    user.bankCards = (user.bankCards || []).filter((c) => c.id !== id);
    saveUsers();
    ok(res, { cards: user.bankCards.map(maskBankCard) });
    return;
  }

  /* 意见反馈：写进 data/feedback.jsonl，后台「用户反馈」里能看 */
  if (parts[0] === 'feedback' && method === 'POST') {
    const body = await readBody(req);
    const content = str(body.content, 1000);
    if (!content) return fail(res, 422, '先写点要反馈的内容');
    const row = {
      id: uid('fb'), userId: user.id, username: user.username, nickname: user.nickname,
      /* 微信那套：先选分类（功能异常 / 产品建议 / 界面样式 / 其他），再写描述，可以贴截图 */
      category: str(body.category, 20) || '功能异常',
      images: (Array.isArray(body.images) ? body.images : [])
        .map((s) => str(s, 300)).filter(Boolean).slice(0, 4),
      contact: str(body.contact, 60), platform: str(body.platform, 20),
      content: content, createdAt: now(),
      status: 'pending', reply: '', repliedAt: '', repliedBy: ''
    };
    try {
      fs.appendFileSync(FEEDBACK_FILE, JSON.stringify(row) + '\n', 'utf8');
    } catch (err) { return fail(res, 500, '提交失败，稍后再试'); }
    ok(res, { sent: true, id: row.id });
    return;
  }

  /* 我的反馈：微信「意见反馈」下面能看到自己提交过的和官方回复 */
  if (parts[0] === 'feedback' && parts[1] === 'mine' && method === 'GET') {
    const rows = readFeedbackRows()
      .filter((r) => r && r.userId === user.id)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, 50)
      .map((r) => ({
        id: r.id, category: r.category || '功能异常', content: r.content || '',
        images: Array.isArray(r.images) ? r.images : [],
        createdAt: r.createdAt || '', status: r.status || 'pending',
        reply: r.reply || '', repliedAt: r.repliedAt || ''
      }));
    ok(res, { rows: rows, total: rows.length });
    return;
  }

  // 退出其他所有设备
  if (parts[0] === 'me' && parts[1] === 'logout-others' && method === 'POST') {
    user.tokenVersion = (user.tokenVersion || 0) + 1;
    saveUsers();
    recordSecurity(user.id, req, 'logout-others');
    ok(res, { loggedOut: true },
      { 'Set-Cookie': sessionCookie(signToken(user.id, req), Math.floor(userSessionTtlMs() / 1000)) });
    return;
  }

  /* 手机把自己拿到的 APNs device token 报上来（App 启动 + 登录后各报一次） */
  if (parts[0] === 'push' && parts[1] === 'register' && method === 'POST') {
    const body = await readBody(req);
    const token = str(body.token, 200).replace(/[^0-9a-fA-F]/g, '').toLowerCase();
    if (token.length < 32) return fail(res, 422, '推送 token 不合法');
    const p = readPush();
    const env = str(body.env, 10) === 'sandbox' ? 'sandbox' : 'prod';
    const list = p.tokens[user.id] || (p.tokens[user.id] = []);
    const exist = list.find((d) => d.token === token);
    if (exist) { exist.env = env; exist.updatedAt = now(); }
    else list.push({ token, env, platform: str(body.platform, 12) || 'ios', updatedAt: now() });
    /* 同一台手机换个账号登录：token 从旧账号名下摘掉，免得推给错的人 */
    Object.keys(p.tokens).forEach((uid) => {
      if (uid === user.id) return;
      p.tokens[uid] = p.tokens[uid].filter((d) => d.token !== token);
      if (!p.tokens[uid].length) delete p.tokens[uid];
    });
    if (p.tokens[user.id] && p.tokens[user.id].length > 5) p.tokens[user.id] = p.tokens[user.id].slice(-5);
    savePush();
    ok(res, { registered: true, devices: (p.tokens[user.id] || []).length });
    return;
  }

  /* 手机把「通知权限开没开 / 标记开没开」报上来：桌面图标没数字时，后台一眼看出卡在哪 */
  if (parts[0] === 'push' && parts[1] === 'settings' && method === 'POST') {
    const body = await readBody(req);
    const p = readPush();
    if (!p.settings) p.settings = {};
    p.settings[user.id] = {
      status: str(body.status, 20) || 'unknown',
      badge: body.badge !== false,
      alert: body.alert !== false,
      sound: body.sound !== false,
      env: str(body.env, 10) === 'sandbox' ? 'sandbox' : 'prod',
      at: now()
    };
    savePush();
    pushLog({
      userId: user.id, kind: 'settings',
      title: '通知设置：' + p.settings[user.id].status + (p.settings[user.id].badge ? ' · 标记开' : ' · 标记关')
    });
    ok(res, { saved: true });
    return;
  }

  /* 退出登录时不推了 */
  if (parts[0] === 'push' && parts[1] === 'unregister' && method === 'POST') {
    const body = await readBody(req);
    const token = str(body.token, 200).replace(/[^0-9a-fA-F]/g, '').toLowerCase();
    if (token) pushRemoveToken(user.id, token);
    ok(res, { removed: true });
    return;
  }

  /* 自检：推送配好了没、这台手机在服务器上登记过没 */
  if (parts[0] === 'push' && parts[1] === 'status' && method === 'GET') {
    const p = readPush();
    ok(res, {
      configured: pushReady(),
      enabled: !!p.config.enabled,
      sandbox: !!p.config.sandbox,
      devices: (p.tokens[user.id] || []).length
    });
    return;
  }

  if (parts[0] === 'users' && parts.length === 2 && method === 'GET') {
    const u = findUser(parts[1]);
    if (!u) return fail(res, 404, '用户不存在');
    /* 别人点开我的资料：如果我有状态，就记一笔「他看过」（微信里点自己的状态能看到「X 人看过」） */
    if (u.id !== user.id && moodAlive(u) && friendshipBetween(user.id, u.id)) {
      try {
        const views = (Array.isArray(u.moodViews) ? u.moodViews : []).filter((v) => v.userId !== user.id);
        views.push({ userId: user.id, at: now() });
        u.moodViews = views.slice(-50);
        saveUsers();
      } catch (e) { }
    }
    const f = friendshipBetween(user.id, u.id);
    const isFriend = !!(f && f.status === 'accepted');
    const online = onlineUserIds();
    const meta = metaOf(user.id, u.id);
    const addedAt = f ? (f.respondedAt || f.createdAt || '') : '';
    ok(res, {
      user: Object.assign(memberProfile(u, user.id), {
        relation: !f ? (u.id === user.id ? 'self' : 'none') : (f.status === 'accepted' ? 'friend' : (f.fromId === user.id ? 'requested' : 'incoming')),
        online: online.includes(u.id),
        banned: !!u.banned,
        momentCount: db.moments.filter((m) => m.authorId === u.id).length,
        phone: (u.id === user.id || isFriend) ? (u.phone || '') : '',
        alipay: (u.id === user.id || isFriend) ? (u.alipay || '') : '',
        mutualGroups: db.chats.filter((c) => c.type === 'group' && c.memberIds.includes(user.id) && c.memberIds.includes(u.id)).length,
        /* 我给他设的朋友资料（备注名/标签/星标/朋友权限）+ 好友关系的来源和添加时间 */
        remark: meta.remark || '',
        realNickname: u.nickname || u.username || '',
        tags: meta.tags || [],
        star: meta.star === true,
        block: meta.block === true,
        noMoments: meta.noMoments === true,
        chatOnly: meta.chatOnly === true,
        addedAt,
        source: f && f.fromId === user.id ? 'me' : (f ? 'them' : '')
      }, (meta.remark && String(meta.remark).trim()) ? { nickname: String(meta.remark).trim() } : {})
    });
    return;
  }

  if (parts[0] === 'users' && method === 'GET') {
    const q = str(query.get('q'), 24).toLowerCase();
    if (!q) return ok(res, { users: [] });            // 空搜索不再把全站用户吐出来
    if (!searchRateAllow(user.id)) return fail(res, 429, '搜索太频繁了，歇一下再搜');
    const online = onlineUserIds();
    const myFriends = friendSetCached(user.id);
    /* 仿微信：微信号 / 手机号要完全对上才出结果，靠字母表一个个扫扫不出来。
       另外补一条：**完整昵称**也能搜到（新用户注册完只知道自己叫什么，
       光靠微信号搜不到人）。自己的好友额外允许昵称模糊匹配。 */
    const exact = (u) => String(u.username || '').toLowerCase() === q
      || String(u.phone || '') === q
      || String(u.nickname || '').toLowerCase() === q;
    let matched = secCfg().strictSearch
      ? db.users.filter((u) => u.id !== user.id && exact(u))
      : db.users.filter((u) => u.id !== user.id &&
          (String(u.username || '').toLowerCase().includes(q) || String(u.nickname || '').toLowerCase().includes(q)));
    if (!matched.length && secCfg().strictSearch) {
      matched = db.users.filter((u) => u.id !== user.id && myFriends.has(u.id) &&
        (String(u.nickname || '').toLowerCase().includes(q) || String(u.username || '').toLowerCase().includes(q)));
    }
    const list = matched.slice(0, 20).map((u) => {
        const f = friendshipBetween(user.id, u.id);
        return Object.assign(publicUserBrief(u, user.id, myFriends), {
          relation: !f ? 'none' : (f.status === 'accepted' ? 'friend' : (f.fromId === user.id ? 'requested' : 'incoming')),
          online: online.includes(u.id)
        });
      });
    ok(res, { users: list });
    return;
  }

  if (parts[0] === 'contacts' && method === 'GET') {
    const online = onlineUserIds();
    /* 公众号**不算好友**：微信里它们只出现在「通讯录 → 公众号」和会话列表，
       不会混进 A-Z 好友列表（用户反馈的「你又造了 2 个机器人出来」就是这个）。 */
    const isOA = (u) => !!(u && (u.oaId || u.oaDigest));
    const friends = friendIds(user.id).map((id) => {
      const u = findUser(id);
      if (!u || isOA(u)) return null;
      /* 好友列表带上「我给他设的资料」：备注名、标签、星标、拉黑、不看朋友圈。
         备注名直接替换昵称 —— 老版本 App 不装包也能看到备注生效。 */
      const m = metaOf(user.id, id);
      return Object.assign(publicUser(u), {
        online: online.includes(id),
        realNickname: u.nickname || u.username || '',
        remark: m.remark || '',
        tags: m.tags || [],
        star: m.star === true,
        block: m.block === true,
        noMoments: m.noMoments === true
        , qqLevel: qqLevelFor(id)          // 通讯录里昵称后面挂等级图标（QQ 那套）
      }, (m.remark && String(m.remark).trim()) ? { nickname: String(m.remark).trim() } : {});
    }).filter(Boolean);
    const incoming = db.friendships
      .filter((f) => f.toId === user.id && f.status === 'pending')
      .map((f) => Object.assign({ requestId: f.id, createdAt: f.createdAt, requestMessage: f.note || '' },
        publicUserBrief(findUser(f.fromId), user.id)));
    const outgoing = db.friendships
      .filter((f) => f.fromId === user.id && f.status === 'pending')
      .map((f) => Object.assign({ requestId: f.id, createdAt: f.createdAt, requestMessage: f.note || '' },
        publicUserBrief(findUser(f.toId), user.id)));
    /* 刚通过的那几个人：微信上会留在「新的朋友」里显示「已添加」，保留 3 天。
       ⚠ 必须**两侧都算**：以前只查 f.toId === user.id（别人加我、我同意的），
       结果「我加了别人、对方同意了」这种情况在我这边根本不出现 ——
       申请已经不是 pending，又不进「已添加」，那一行就凭空消失了
       （用户反馈的「新的朋友已经接受了但还是没刷新」就是这个）。 */
    const added = db.friendships
      .filter((f) => f.status === 'accepted'
        && (f.toId === user.id || f.fromId === user.id)
        && (Date.parse(f.respondedAt || f.createdAt) || 0) > Date.now() - 3 * 86400000)
      .sort((a, b) => String(b.respondedAt || b.createdAt).localeCompare(String(a.respondedAt || a.createdAt)))
      .slice(0, 30)
      .map((f) => {
        const otherId = f.toId === user.id ? f.fromId : f.toId;   // 对面那个人
        const u = findUser(otherId);
        if (!u) return null;
        return Object.assign({ requestId: f.id, createdAt: f.createdAt, requestMessage: f.note || '' },
          publicUserBrief(u, user.id));
      })
      .filter(Boolean);
    ok(res, { friends, incoming, outgoing, added });
    return;
  }

  if (parts[0] === 'friends' && parts[1] === 'request' && method === 'POST') {
    const body = await readBody(req);
    const target = str(body.username, 24) ? findUserByName(body.username) : findUser(str(body.userId, 40));
    if (!target) return fail(res, 404, '用户不存在');
    if (target.id === user.id) return fail(res, 422, '不能添加自己');
    /* 风控：被临时限制的账号先挡住；加得太快记一笔（营销号/养号特征） */
    const fReqBlocked = riskBlocked(user);
    if (fReqBlocked) return fail(res, 429, '账号功能被临时限制，还有 ' + fReqBlocked + ' 分钟（如有疑问请联系管理员）');
    noteFriendReqRisk(user);
    /* 隐私：对方关掉「通过微信号找到我」就不给加（手机号那条走注册/绑定那条路） */
    const tp = userPrivacy(target);
    if (str(body.username, 24) && !tp.addByWx) return fail(res, 403, '对方关闭了「通过微信号添加我」');
    /* 从群里点人加好友：对方关了「通过群聊添加我」也拦 */
    if (str(body.from, 12) === 'group' && !tp.addByGroup) return fail(res, 403, '对方关闭了「通过群聊添加我」');
    const exist = friendshipBetween(user.id, target.id);
    if (exist) {
      if (exist.status === 'accepted') return fail(res, 409, '你们已经是好友');
      if (exist.fromId === user.id) return fail(res, 409, '已经发送过好友请求');
      exist.status = 'accepted';
      exist.respondedAt = now();
      saveFriendships();
      /* 互相加好友（对方先加过我）：同样立刻在两个人的「微信」首页开出会话 */
      const c2 = openChatForFriendship(exist.fromId, exist.toId);
      sendTo(target.id, { type: 'friend', action: 'accepted', user: publicUser(user) });
      sendTo(exist.fromId, { type: 'chat', chatId: c2 ? c2.id : '' });
      sendTo(exist.toId, { type: 'chat', chatId: c2 ? c2.id : '' });
      return ok(res, { accepted: true, friend: publicUser(target) });
    }
    /* 对方关了「加我为朋友时需要验证」→ 直接变成好友，不再等他点同意 */
    if (!tp.needVerify) {
      const auto = { id: uid('f'), fromId: target.id, toId: user.id, status: 'accepted', createdAt: now(),
        respondedAt: now() };
      db.friendships.push(auto);
      saveFriendships();
      const c0 = openChatForFriendship(target.id, user.id);
      sendTo(target.id, { type: 'friend', action: 'accepted', user: publicUser(user) });
      sendTo(user.id, { type: 'chat', chatId: c0 ? c0.id : '' });
      sendTo(target.id, { type: 'chat', chatId: c0 ? c0.id : '' });
      return ok(res, { accepted: true, friend: publicUser(target) });
    }
    /* 微信那套：申请里那句「我是XXX」要留着，「新的朋友」页上要显示出来 */
    const f = { id: uid('f'), fromId: user.id, toId: target.id, status: 'pending', createdAt: now(),
      note: str(body.message, 60) };
    db.friendships.push(f);
    saveFriendships();
    sendTo(target.id, { type: 'friend', action: 'request', requestId: f.id, user: publicUser(user) });
    /* 对方手机没连着 → 推一条「新的朋友」 */
    pushToUser(target.id, {
      kind: 'friend',
      title: '新的朋友',
      body: (user.nickname || user.username || '有人') + ' 请求添加你为好友' + (f.note ? '：' + f.note : '')
    }).catch(() => { });
    ok(res, { requestId: f.id, to: publicUser(target) });
    return;
  }

  /* 朋友资料：备注名 / 标签 / 星标 / 朋友权限 / 拉黑（微信「设置备注和标签」那一套） */
  if (parts[0] === 'friends' && parts[1] === 'meta' && method === 'POST') {
    const body = await readBody(req);
    const target = findUser(str(body.userId, 40));
    if (!target) return fail(res, 404, '用户不存在');
    if (target.id === user.id) return fail(res, 422, '不能给自己设备注');
    const patch = {};
    if (body.remark !== undefined) patch.remark = str(body.remark, 24).trim();
    if (body.tags !== undefined) {
      const raw = Array.isArray(body.tags) ? body.tags
        : String(body.tags || '').split(/[，,\s]+/).filter(Boolean);
      patch.tags = raw.map((t) => String(t).trim()).filter(Boolean).slice(0, 10);
    }
    ['star', 'block', 'noMoments', 'chatOnly', 'hideMyMoments'].forEach((k) => {
      if (body[k] !== undefined) patch[k] = !!body[k];
    });
    const saved = setMeta(user.id, target.id, patch);
    /* 拉黑/取消拉黑：会话、通讯录、对方那边都要跟着变 */
    sendTo(user.id, { type: 'friend', action: 'meta', userId: target.id });
    ok(res, {
      meta: {
        remark: saved.remark || '', tags: saved.tags || [],
        star: saved.star === true, block: saved.block === true,
        noMoments: saved.noMoments === true, chatOnly: saved.chatOnly === true
      }
    });
    return;
  }

  if (parts[0] === 'friends' && parts[1] === 'meta' && method === 'GET') {
    const target = findUser(str(query.get('userId'), 40));
    if (!target) return fail(res, 404, '用户不存在');
    const f = friendshipBetween(user.id, target.id);
    const m = metaOf(user.id, target.id);
    ok(res, {
      meta: {
        remark: m.remark || '', tags: m.tags || [],
        star: m.star === true, block: m.block === true,
        noMoments: m.noMoments === true, chatOnly: m.chatOnly === true,
        hideMyMoments: m.hideMyMoments === true
      },
      addedAt: f ? (f.respondedAt || f.createdAt || '') : '',
      source: f && f.fromId === user.id ? 'me' : (f ? 'them' : ''),
      blockedMe: blockedByUser(target.id, user.id)
    });
    return;
  }

  /* 删除好友（微信：对方还在你的列表里，只是彼此不再是好友，聊天记录可选删） */
  if (parts[0] === 'friends' && parts[1] === 'remove' && method === 'POST') {
    const body = await readBody(req);
    const target = findUser(str(body.userId, 40));
    if (!target) return fail(res, 404, '用户不存在');
    const f = friendshipBetween(user.id, target.id);
    if (!f) return fail(res, 404, '你们还不是好友');
    db.friendships = db.friendships.filter((x) => x.id !== f.id);
    saveFriendships();
    /* 只动我这边：把会话从我的列表里藏掉（对方那边不受影响，微信就是这样） */
    const chat = db.chats.find((c) => c.type === 'direct' && c.memberIds.includes(user.id) && c.memberIds.includes(target.id));
    if (chat) {
      if (!Array.isArray(chat.hiddenFor)) chat.hiddenFor = [];
      if (!chat.hiddenFor.includes(user.id)) chat.hiddenFor.push(user.id);
      chatsDirty = true;
      sendTo(user.id, { type: 'chat', action: 'deleted', chatId: chat.id });
    }
    /* 备注之类的一并清掉 */
    const dbm = readFriendMeta();
    if (dbm.byOwner[user.id]) {
      delete dbm.byOwner[user.id][target.id];
      saveFriendMeta();
    }
    sendTo(user.id, { type: 'friend', action: 'removed', userId: target.id });
    ok(res, { removed: true });
    return;
  }

  if (parts[0] === 'friends' && parts[1] === 'respond' && method === 'POST') {
    const body = await readBody(req);
    /* 两种传法都收：
       · requestId ——「通讯录 → 新的朋友」列表里本来就带着
       · userId    ——对方名片上直接点「同意」用的；以前要先拉一遍整份通讯录
                     才能找到 requestId，点一下要等两次网络来回，所以显得很慢 */
    const reqId = str(body.requestId, 40);
    const fromId = str(body.userId, 40);
    const f = reqId
      ? db.friendships.find((x) => x.id === reqId)
      : db.friendships.find((x) => x.fromId === fromId && x.toId === user.id && x.status === 'pending');
    if (!f || f.toId !== user.id || f.status !== 'pending') return fail(res, 404, '好友请求不存在');
    /* 处理完还剩几个待处理：回给客户端，红点数字不用再拉一遍通讯录 */
    const pendingLeft = () => db.friendships
      .filter((x) => x.toId === user.id && x.status === 'pending').length;
    if (body.accept) {
      f.status = 'accepted';
      f.respondedAt = now();
      saveFriendships();
      /* 通过好友以后，两个人的「微信」首页立刻各多一个会话（不用等谁先说话） */
      const newChat = openChatForFriendship(f.fromId, f.toId);
      /* 和微信一样：通过以后聊天里留一条系统提示 */
      try {
        const fromUser = findUser(f.fromId);
        const toUser = findUser(f.toId);
        if (newChat && fromUser && toUser) {
          pushSystemMessage(newChat, '你已添加了' + (fromUser.nickname || fromUser.username)
            + '，现在可以开始聊天了');
        }
      } catch (e) { /* 提示加不上不影响通过 */ }
      sendTo(f.fromId, { type: 'friend', action: 'accepted', user: publicUser(user) });
      sendTo(f.fromId, { type: 'chat', chatId: newChat ? newChat.id : '' });
      sendTo(f.toId, { type: 'chat', chatId: newChat ? newChat.id : '' });
      ok(res, { accepted: true, friend: publicUser(findUser(f.fromId)), pending: pendingLeft() });
    } else {
      db.friendships = db.friendships.filter((x) => x.id !== f.id);
      saveFriendships();
      ok(res, { rejected: true, pending: pendingLeft() });
    }
    return;
  }

  if (parts[0] === 'chats' && method === 'GET' && parts.length === 1) {
    // 一次把最近几个会话的消息也带上：登录时「同步最近的聊天记录」用的就是这个
    if (query.get('withMessages') === '1') {
      const chatCount = Math.min(30, Math.max(1, Number(query.get('syncChats')) || 10));
      const perChat = Math.min(100, Math.max(5, Number(query.get('syncLimit')) || 30));
      /* 和普通列表一样排序：置顶 → 贾维斯AI → 其它机器人 → 按时间 */
      const sortChats = (arr) => arr.slice().sort((a, b) => {
        const pa = (a.pinnedFor || []).includes(user.id), pb = (b.pinnedFor || []).includes(user.id);
        if (pa !== pb) return pa ? -1 : 1;
        const rankOf = (c) => {
          if (c.type !== 'direct') return 9;
          const other = findUser(c.memberIds.find((id) => id !== user.id) || '');
          if (!other || !other.bot) return 9;
          return other.username === 'housekeeper' ? 0 : (other.username === AI_USERNAME ? 1 : 2);
        };
        const ra = rankOf(a), rb = rankOf(b);
        if (ra !== rb) return ra - rb;
        return String(b.updatedAt).localeCompare(String(a.updatedAt));
      });
      const mine = sortChats(chatsOf(user.id).slice());
      const list = mine.map((c) => chatSummary(c, user.id));
      const batch = mine.slice(0, chatCount).map((c) => ({
        id: c.id,
        title: chatSummary(c, user.id).title,
        messages: loadMessages(c.id).slice(-perChat).map((m) => Object.assign({}, m, {
          senderName: displayNameFor(user.id, findUser(m.senderId)),
          senderAvatar: (findUser(m.senderId) || {}).avatar || ''
        }))
      }));
      ok(res, { chats: list, sync: { chats: batch, syncedAt: now() } });
      return;
    }
    const list = chatsOf(user.id)
      .map((c) => chatSummary(c, user.id))
      .sort((a, b) => {
        if (!!a.pinned !== !!b.pinned) return a.pinned ? -1 : 1;   // 置顶会话永远在最上面（QQ 就是这样）
        const ra = a.botRank == null ? 9 : a.botRank, rb = b.botRank == null ? 9 : b.botRank;
        if (ra !== rb) return ra - rb;                            // 贾维斯AI 固定第一，其次其它机器人
        return String(b.updatedAt).localeCompare(String(a.updatedAt));
      });
    ok(res, { chats: list });
    return;
  }

  if (parts[0] === 'chats' && parts[1] === 'direct' && method === 'POST') {
    const body = await readBody(req);
    const target = findUser(str(body.userId, 40));
    if (!target) return fail(res, 404, '用户不存在');
    // 自己给自己发消息也允许（名片里的「发消息」按钮）
    if (target.id !== user.id && !friendIds(user.id).includes(target.id) && !readIm().allowStranger) {
      return fail(res, 403, '先加为好友才能聊天');
    }
    let chat = directChatBetween(user.id, target.id);
    if (!chat) {
      chat = {
        id: uid('c'), type: 'direct', name: '', avatar: '',
        memberIds: [user.id, target.id], ownerId: user.id, seq: 0, createdAt: now()
      };
      db.chats.push(chat);
      saveChats();
      sendTo(target.id, { type: 'chat', action: 'created', chat: chatSummary(chat, target.id) });
    }
    ok(res, { chat: chatSummary(chat, user.id) });
    return;
  }

  if (parts[0] === 'chats' && parts[1] === 'group' && method === 'POST') {
    const body = await readBody(req);
    const im = readIm();
    if (!im.allowCreateGroup) return fail(res, 403, '管理员关闭了建群');
    const name = str(body.name, 30);
    if (!name) return fail(res, 422, '请填写群名称');
    const allowed = friendIds(user.id);
    const ids = (Array.isArray(body.memberIds) ? body.memberIds : [])
      .map((x) => str(x, 40))
      .filter((id) => id && id !== user.id && findUser(id) && allowed.includes(id));
    const members = Array.from(new Set([user.id].concat(ids)));
    if (members.length < 2) return fail(res, 422, '至少选择一个好友');
    if (members.length > im.maxGroupMembers) return fail(res, 422, '群人数最多 ' + im.maxGroupMembers + ' 人');
    const chat = {
      id: uid('c'), type: 'group', name, avatar: str(body.avatar, 300000),
      memberIds: members, ownerId: user.id, seq: 0, createdAt: now()
    };
    db.chats.push(chat);
    /* 没自带群头像就按成员头像拼一张九宫格（微信那种效果） */
    if (!chat.avatar) buildGroupAvatar(chat);
    saveChats();
    members.forEach((id) => {
      if (id !== user.id) sendTo(id, { type: 'chat', action: 'created', chat: chatSummary(chat, id) });
    });
    ok(res, { chat: chatSummary(chat, user.id) });
    return;
  }

  /* -------------------------------------------------------- 面对面建群 */
  // 微信那种：大家输入同一个 4 位数字，就进同一个群；数字 3 分钟内有效
  if (parts[0] === 'chats' && parts[1] === 'face' && method === 'POST') {
    const body = await readBody(req);
    const code = String(body.code == null ? '' : body.code).trim();
    if (!/^[0-9]{4}$/.test(code)) return fail(res, 422, '请输入 4 位数字');
    /* 安全：4 位数字只有 1 万种，脚本一路试过去，几十秒就能撞进别人的面对面群。
       所以每人 10 分钟最多试 10 次（正常建群一次就够）。 */
    if (!faceCodeRateAllow(user.id)) {
      strikeIp(clientInfo(req).ip, '狂试面对面群码');
      return fail(res, 429, '试得太频繁了，10 分钟后再建群');
    }
    const t = Date.now();
    pruneFaceRooms();
    let room = db.faceRooms.find((r) => r.code === code && r.expiresAt > t) || null;
    let chat = room ? db.chats.find((c) => c.id === room.chatId) : null;
    if (room && !chat) {
      db.faceRooms = db.faceRooms.filter((r) => r !== room);
      room = null;
    }
    let created = false;
    let joined = false;
    if (!room) {
      chat = {
        id: uid('c'), type: 'group', name: '面对面建群 · ' + code, avatar: '',
        memberIds: [user.id], ownerId: user.id, seq: 0, createdAt: now(), faceCode: code
      };
      db.chats.push(chat);
      room = { code, chatId: chat.id, createdAt: now(), expiresAt: t + FACE_ROOM_WINDOW_MS, joinedCount: 1 };
      db.faceRooms.push(room);
      created = true;
    } else {
      room.expiresAt = t + FACE_ROOM_WINDOW_MS; // 每次有人进来，有效期重新计时
      if (!chat.memberIds.includes(user.id)) {
        chat.memberIds.push(user.id);
        room.joinedCount = (room.joinedCount || chat.memberIds.length) + 1;
        joined = true;
      }
    }
    if (created || joined) {
      chat.seq = (chat.seq || 0) + 1;
      /* 群成员变了：重拼一次九宫格群头像（面对面建群也是一样） */
      buildGroupAvatar(chat);
      const text = created ? '你创建了面对面群聊（数字 ' + code + '）'
        : (user.nickname + ' 通过面对面建群加入，数字 ' + code);
      const sysMsg = {
        id: uid('m'), chatId: chat.id, seq: chat.seq, senderId: 'system',
        kind: 'system', content: text, createdAt: now(), recalled: false
      };
      appendMessage(chat.id, sysMsg);
      chat.memberIds.forEach((id) => {
        sendTo(id, { type: 'message', message: sysMsg, chat: chatSummary(chat, id), clientId: null });
      });
    }
    saveChats();
    saveFaceRooms();
    if (joined) {
      chat.memberIds.forEach((id) => {
        if (id === user.id) return;
        sendTo(id, {
          type: 'chat', action: 'created', chat: chatSummary(chat, id),
          notice: user.nickname + ' 通过面对面建群加入了群聊'
        });
      });
    }
    ok(res, {
      chat: chatSummary(chat, user.id),
      created, joined,
      memberCount: chat.memberIds.length,
      expiresIn: Math.max(0, Math.round((room.expiresAt - Date.now()) / 1000))
    });
    return;
  }

  // 置顶 / 取消置顶会话（只对自己生效，QQ 右键菜单里的「置顶会话」）
  if (parts[0] === 'chats' && parts[2] === 'pin' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    const body = await readBody(req);
    const set = new Set(chat.pinnedFor || []);
    const hasBot = chat.memberIds.map(findUser).some((u) => u && u.bot);
    if (hasBot) {
      set.add(user.id);                       // 机器人会话永远置顶，取消不了
    } else if (body.pinned === false) {
      set.delete(user.id);
    } else {
      set.add(user.id);
    }
    chat.pinnedFor = Array.from(set);
    saveChats();
    ok(res, { pinned: chat.pinnedFor.includes(user.id), forced: hasBot });
    return;
  }

  // 删除会话：只从自己的列表里移除（对齐 QQ 的右键删除），对方不受影响
  if (parts[0] === 'chats' && parts.length === 2 && method === 'DELETE') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    /* 贾维斯AI / AI 助手 / 星联世界：以前是「固定置顶、不允许删」。
       用户要求**这几个置顶的机器人也可以删掉** —— 现在删了就只对自己隐藏，
       同时把「自动置顶」也撤掉（不然它还会被顶回会话列表最上面）。 */
    const botPeer = chat.memberIds.filter((id) => id !== user.id)
      .map((id) => findUser(id)).find((u) => u && u.bot);
    if (botPeer) {
      chat.hiddenFor = Array.from(new Set((chat.hiddenFor || []).concat([user.id])));
      chat.pinnedFor = (chat.pinnedFor || []).filter((id) => id !== user.id);
      saveChats();
      ok(res, { hidden: true, chatId: chat.id, bot: true });
      return;
    }
    chat.hiddenFor = Array.from(new Set((chat.hiddenFor || []).concat([user.id])));
    saveChats();
    ok(res, { hidden: true, chatId: chat.id });
    return;
  }

  /* ============================================================
     聊天记录导出 / 导入（微信的「聊天记录迁移与备份」）
       导出 GET  /api/chats/export?chatId=xxx&format=json|txt
             不带 chatId 就是导出全部；JSON 可以再导入，TXT 是给人看的
       导入 POST /api/chats/import   { payload: <导出的 JSON> }
             按消息 id 去重（导两次也不会重复），导入后按时间重排、重编 seq
     ============================================================ */
  if (parts[0] === 'chats' && parts[1] === 'export' && method === 'GET') {
    const format = String(query.get('format') || 'json').toLowerCase() === 'txt' ? 'txt' : 'json';
    const one = str(query.get('chatId'), 60);
    const mine = chatsOf(user.id).filter((c) => !one || c.id === one);
    if (one && !mine.length) return fail(res, 404, '这个会话不在你名下');

    const picked = [];
    let total = 0;
    for (const c of mine) {
      const msgs = loadMessages(c.id);
      if (!msgs.length) continue;
      total += msgs.length;
      if (total > 60000) break;          // 一次别导太多，内存撑不住
      picked.push({ chat: c, messages: msgs });
    }

    const titleOf = (c) => {
      if (c.type === 'group') return c.name || '群聊';
      const other = findUser((c.memberIds || []).find((id) => id !== user.id) || '');
      return other ? displayNameFor(user.id, other) : '聊天';
    };
    const memberList = (c) => (c.memberIds || []).map((id) => ({
      id,
      name: id === user.id ? (user.nickname || user.username || '我') : displayNameFor(user.id, findUser(id))
    }));
    const stamp = new Date().toISOString().slice(0, 10);

    if (format === 'txt') {
      const lines = [];
      lines.push('Luchat 聊天记录备份 · 导出于 ' + now());
      lines.push('账号：' + (user.nickname || user.username || user.id));
      lines.push('');
      picked.forEach(({ chat, messages }) => {
        lines.push('========== ' + titleOf(chat) + '（共 ' + messages.length + ' 条） ==========');
        messages.forEach((m) => {
          const who = m.senderId === user.id ? '我'
            : (displayNameFor(user.id, findUser(m.senderId)) || '对方');
          const body = m.recalled ? '[消息已撤回]' : previewTextOf(m);
          lines.push('[' + String(m.createdAt || '').replace('T', ' ').slice(0, 19) + '] ' + who + '：' + body);
        });
        lines.push('');
      });
      ok(res, {
        fileName: 'luchat-chat-' + stamp + '.txt',
        format: 'txt',
        total,
        chats: picked.length,
        data: lines.join('\n')
      });
      return;
    }

    ok(res, {
      fileName: 'luchat-chat-' + stamp + '.json',
      format: 'json',
      total,
      chats: picked.length,
      data: {
        app: 'Luchat',
        version: 1,
        exportedAt: now(),
        user: { id: user.id, username: user.username || '', nickname: user.nickname || '' },
        chats: picked.map(({ chat, messages }) => ({
          id: chat.id,
          type: chat.type,
          title: titleOf(chat),
          memberIds: chat.memberIds || [],
          members: memberList(chat),
          messages: messages.map((m) => ({
            id: m.id,
            seq: m.seq,
            senderId: m.senderId,
            senderName: m.senderId === user.id ? (user.nickname || '我')
              : (displayNameFor(user.id, findUser(m.senderId)) || ''),
            kind: m.kind || 'text',
            content: m.content || '',
            createdAt: m.createdAt,
            recalled: !!m.recalled
          }))
        }))
      }
    });
    return;
  }

  if (parts[0] === 'chats' && parts[1] === 'import' && method === 'POST') {
    const body = await readBody(req);
    let payload = body.payload;
    if (typeof payload === 'string') {
      try { payload = JSON.parse(payload); } catch (e) { return fail(res, 422, '文件内容不是聊天记录备份'); }
    }
    if (!payload || !Array.isArray(payload.chats)) return fail(res, 422, '文件内容不是聊天记录备份');

    const allowedKinds = ['text', 'image', 'file', 'audio', 'gift', 'transfer', 'location', 'redpacket', 'link'];
    const MAX_TOTAL = 30000;
    let imported = 0;
    let skipped = 0;
    const touched = [];

    for (const item of payload.chats.slice(0, 300)) {
      if (!item || !Array.isArray(item.messages) || !item.id) continue;
      let chat = db.chats.find((c) => c.id === item.id);
      if (chat && !chat.memberIds.includes(user.id)) { skipped += item.messages.length; continue; }
      if (!chat) {
        /* 会话不在了（换手机 / 换了账号）：单聊就按导出里的成员重建一条，
           对方账号不存在（注销了）就只挂在自己名下，记录还能看 */
        const others = (item.memberIds || []).filter((id) => id !== user.id && findUser(id));
        chat = {
          id: String(item.id).slice(0, 60),
          type: item.type === 'group' ? 'group' : 'direct',
          name: item.type === 'group' ? String(item.title || '群聊').slice(0, 40) : '',
          memberIds: [user.id].concat(others),
          seq: 0,
          createdAt: now(),
          updatedAt: now()
        };
        db.chats.push(chat);
        touched.push(chat.id);
        chatsDirty = true;
      }

      const existing = loadMessages(chat.id);
      const have = new Set(existing.map((m) => m.id));
      const merged = existing.slice();
      for (const m of item.messages) {
        if (!m || !m.id || have.has(String(m.id))) { skipped += 1; continue; }
        if (imported >= MAX_TOTAL) break;
        have.add(String(m.id));
        const kind = allowedKinds.includes(m.kind) ? m.kind : 'text';
        merged.push({
          id: String(m.id).slice(0, 60),
          chatId: chat.id,
          seq: 0,
          senderId: String(m.senderId || user.id),
          kind,
          content: String(m.content == null ? '' : m.content).slice(0, 8000),
          createdAt: String(m.createdAt || now()),
          recalled: !!m.recalled
        });
        imported += 1;
      }
      if (merged.length === existing.length) continue;

      /* 按时间重排、重编 seq：导入的旧消息要回到它们该在的位置 */
      merged.sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)));
      merged.forEach((m, i) => { m.seq = i + 1; m.chatId = chat.id; });
      chat.seq = merged.length;
      chat.updatedAt = now();
      saveMessagesFile(chat.id, merged);
      chatsDirty = true;
      /* 导入的历史不算未读 */
      if (!db.reads[user.id]) db.reads[user.id] = {};
      db.reads[user.id][chat.id] = chat.seq;
      readsDirty = true;
      if (!touched.includes(chat.id)) touched.push(chat.id);
    }

    if (imported) saveUsers();
    audit(req, { username: user.username, name: user.nickname, role: '用户' }, '导入聊天记录', user.username,
      '导入 ' + imported + ' 条，跳过 ' + skipped + ' 条，涉及 ' + touched.length + ' 个会话');
    ok(res, { imported, skipped, chats: touched.length });
    return;
  }

  if (parts[0] === 'chats' && parts[2] === 'messages' && method === 'GET') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');
    const limit = Math.min(100, Math.max(1, Number(query.get('limit')) || 30));
    const before = Number(query.get('before')) || Number.MAX_SAFE_INTEGER;
    /* 自己清空过聊天记录：清空点之前的一律不返回（别人不受影响） */
    const clearedSeq = ((db.cleared || {})[user.id] || {})[chat.id] || 0;
    /* ⚠ 超长会话保护（2026-10-11）：一条会话一次最多只给最近 300 条，
       更早的不再返回 —— 客户端往上滑也不会一直往内存里堆（700 条 / 内容高
       4.8 万 pt 会把 App 拖到被系统杀掉，家人群就是这么崩的）。 */
    /* ⚠ 2026-10-11 晚：这个上限原来是写死 300 条，结果用户反馈「聊天内容只到前天、
       再往上就没了」—— 家人群两天就有 300+ 条，一刀切在 300 就等于把更早的全藏了。
       现在改成可调：data/ui.json 里写 maxHistory（默认 1000），不用重启服务。 */
    /* 2026-10-11 晚（照微信那套）：一次取多少**不再设全局上限** —— 上限交给"服务端保留期"
       （messages-retention.js，默认 7 天，ui.json 的 retentionDays 可调）+ 客户端按页往回要。
       ui.json 的 maxHistory 写 0 或不写 = 不截；写正数就是"一次最多给这么多条"。 */
    const uiCfgHist = readJson(path.join(DATA_DIR, 'ui.json'), {});
    const cap = Number(uiCfgHist.maxHistory) || 0;      // 0 = 不设上限
    const allMsgs = loadMessages(chat.id);
    const capFromSeq = (cap > 0 && allMsgs.length > cap) ? (allMsgs[allMsgs.length - cap].seq || 0) : 0;
    const slice = allMsgs
      .filter((m) => m.seq < before && m.seq > clearedSeq && m.seq >= capFromSeq).slice(-limit);
    /* 拉历史消息的人可能是老版本：名片这类卡片消息要降级成纯文本，否则他那边是乱码 */
    const reqBuild = Number((String(req.headers['x-app-build'] || '').match(/B(\d+)/) || [])[1] || 0);
    const messages = slice.map((m) => {
      const one = Object.assign({}, m, {
        /* 群里显示群昵称（和微信一致），单聊就是备注/昵称 */
        senderName: chat.type === 'group'
          ? groupNameFor(chat, user.id, findUser(m.senderId))
          : displayNameFor(user.id, findUser(m.senderId)),
        senderAvatar: (findUser(m.senderId) || {}).avatar || ''
      });
      /* CHRIS_BURN_V1 阅后即焚：带上「这条什么时候烧」（客户端画倒计时）。
         看过 = seenAt + 20 秒；还没人看过就先不给时间（客户端只显示小火苗）。 */
      if (one.burn) {
        one.burnAt = m.seenAt ? new Date(m.seenAt + BURN_HOLD_MS).toISOString() : '';
      }
      if (reqBuild < CARD_MIN_BUILD && one.kind === 'card') {
        const nm = cardFallbackName(one.content);
        one.kind = 'text';
        one.content = nm ? ('[名片] ' + nm) : '[名片]';
      } else if (one.kind === 'card') {
        /* 读历史时把名片补全：老的那几张 content 里存的可能就是一串号，
           这里用服务端最新资料重写一遍（名字优先取我对他的备注） */
        try {
          const o = JSON.parse(String(one.content || '{}'));
          const t = findUser(String(o.userId || ''));
          if (t) {
            o.name = displayNameFor(user.id, t) || t.nickname || t.username || '';
            o.username = t.username || '';
            o.avatar = t.avatar || '';
            one.content = JSON.stringify(o);
          }
        } catch (err) { /* 解析不出来就原样给 */ }
      }
      /* 图片宽高（骨架落位）：老消息里没有，这里从文件头补上 ——
         客户端拿到就能按真实比例先占好位，不会等图下完再撑开。 */
      if (one.kind === 'image' && !(Number(one.imgW) > 1 && Number(one.imgH) > 1)) {
        const d = imageDimsOf(one.content);
        if (d) { one.imgW = d.w; one.imgH = d.h; }
      }
      return one;
    });
    ok(res, { chat: chatSummary(chat, user.id), messages, hasMore: slice.length === limit });
    return;
  }

  if (parts[0] === 'chats' && parts[2] === 'messages' && method === 'POST') {
    const body = await readBody(req);
    if (!msgRateAllow(user.id) || !globalMsgAllow()) {
      riskEvent(user, 'fast_send', { note: '触发消息限流' });      // 频率异常记一笔（不罚，累计到阈值才受限）
      return fail(res, 429, '发得太快了，歇一秒再发');
    }
    /* 风控：被临时限制的账号先挡住 */
    const rw = riskBlocked(user);
    if (rw) return fail(res, 429, '账号功能被临时限制，还有 ' + rw + ' 分钟（如有疑问请联系管理员）');
    /* 图片 / 视频 / 文件：违规账号（或风控分偏高）一律发不出去 —— 用户要求
       「和黄赌毒有关的文字、视频全都发不出来」，文字走敏感词，媒体走这条。 */
    if ((body.kind || 'text') !== 'text') {
      const mwhy = mediaBlockedReason(user);
      if (mwhy) return fail(res, 403, mwhy);
    }
    /* 文字炸弹（几千个换行 / 几千个一样的字）会让手机排版卡死，先洗一遍 */
    let clean = (body.kind || 'text') === 'text' ? sanitizeText(body.content) : body.content;
    if ((body.kind || 'text') === 'text') {
      const sameTo = noteTextSend(user.id, parts[1], clean);      // 群发检测
      if (sameTo >= 5) riskEvent(user, 'mass_send', { note: '同一内容发给了 ' + sameTo + ' 个会话' });
      if (/https?:\/\/|www\./i.test(String(clean || ''))) riskEvent(user, 'link', { note: '消息里带外链' });
    }
    /* 离线重发去重：同一个 clientId 已经落过盘了，就把那一条原样返回，
       不再发第二条（弱网下「其实发出去了但没收到回执」很容易发生）。 */
    if (body.clientId) {
      const cid = String(body.clientId).slice(0, 60);
      const recent = loadMessages(parts[1]).slice(-60);
      const dup = recent.find((m) => m.clientId === cid && m.senderId === user.id);
      if (dup) return ok(res, { message: dup });
    }
    /* 名片：正文只信 userId，名字/头像/微信号一律用服务端最新的资料再补一遍。
       发送端可能拿着旧数据、或者只有 username，用户反馈的「发出去显示成个号」就是这个。
       名字优先取「发送方对他的备注」—— 微信名片上显示的就是备注名。 */
    if ((body.kind || 'text') === 'card') {
      try {
        const cardObj = JSON.parse(String(clean || '{}'));
        const target = findUser(String(cardObj.userId || ''));
        if (target) {
          cardObj.name = displayNameFor(user.id, target) || target.nickname || target.username || '';
          cardObj.username = target.username || '';
          cardObj.avatar = target.avatar || '';
          clean = JSON.stringify(cardObj);
        }
      } catch (err) { /* 解析不出来就原样存 */ }
    }
    const result = deliverMessage(user, parts[1], body.kind || 'text', clean, body.clientId, body.mentions,
      { imgW: body.imgW, imgH: body.imgH, quote: body.quote });
    if (result.error) return fail(res, 422, result.error);
    /* 自己刚发的这条：群里要带上群昵称（客户端是直接拿这条追加到列表里的） */
    let sent = result.message;
    if (sent) {
      const c = db.chats.find((x) => x.id === sent.chatId);
      if (c && c.type === 'group') {
        sent = Object.assign({}, sent, { senderName: groupNameFor(c, user.id, user) });
      }
    }
    ok(res, { message: sent });
    return;
  }

  if (parts[0] === 'chats' && parts[2] === 'read' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');
    const messages = loadMessages(chat.id);
    const lastSeq = messages.length ? messages[messages.length - 1].seq : 0;
    if (!db.reads[user.id]) db.reads[user.id] = {};
    db.reads[user.id][chat.id] = lastSeq;
    saveReads();
    /* CHRIS_BURN_V1 「打开会话 = 看过了」：这一刻就把小火苗那几条标上 seenAt ——
       计时从**点开聊天**开始（客户端上的倒计时也就能立刻出来），
       20 秒后由服务端的定时器真实删掉（内存 + 文件都删）。 */
    try {
      let touched = false;
      messages.forEach((m) => {
        if (!m || !m.burn) return;
        if (m.senderId === user.id) return;              // 自己发的不算「我看了」
        if (!m.seenAt) { m.seenAt = Date.now(); touched = true; }
        if (!m.seenBy) m.seenBy = [];
        if (m.seenBy.indexOf(user.id) < 0) m.seenBy.push(user.id);
        burnWatch.add(chat.id);
      });
      if (touched) saveMessagesFile(chat.id, messages);
    } catch (e) { }
    /* 打开会话就把「标为未读」的小红点清掉 */
    if ((chat.flaggedUnread || []).includes(user.id)) {
      chat.flaggedUnread = chat.flaggedUnread.filter((id) => id !== user.id);
      saveChats();
    }
    sendToChat(chat, { type: 'read', chatId: chat.id, userId: user.id, seq: lastSeq }, user.id);
    ok(res, { seq: lastSeq });
    return;
  }

  /* 群聊信息页：群成员资料 + 群主 + 建群时间
     顺序和九宫格群头像一致（群主排第一），客户端照着画成员格子就行 */
  if (parts[0] === 'chats' && parts[2] === 'members' && method === 'GET') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    const ownerId = chat.ownerId && chat.memberIds.includes(chat.ownerId) ? chat.ownerId : '';
    const ordered = (ownerId ? [ownerId] : []).concat(chat.memberIds.filter((id) => id !== ownerId));
    ok(res, {
      name: chat.name || '',
      avatar: chat.avatar || '',
      ownerId: ownerId,
      createdAt: chat.createdAt || '',
      memberCount: chat.memberIds.length,
      /* alias = 群昵称（微信「设置群昵称」），没设就是空串 */
      members: ordered.map((id) => {
        const u = publicUser(findUser(id));
        if (!u) return null;
        u.alias = memberAlias(chat, id);
        u.qqLevel = qqLevelFor(id);        // 群成员列表里名字旁边也挂等级
        return u;
      }).filter(Boolean)
    });
    return;
  }

  /* 群昵称（微信「设置群昵称」/「我在本群的昵称」）
     自己的随时能改；改别人的只有群主（微信的规矩）。
     传空字符串 = 取消群昵称。 */
  if (parts[0] === 'chats' && parts[2] === 'alias' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || chat.type !== 'group') return fail(res, 404, '群聊不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个群里');
    const body = await readBody(req);
    const targetId = str(body.userId, 40) || user.id;
    if (!chat.memberIds.includes(targetId)) return fail(res, 404, '这个人不在群里');
    if (targetId !== user.id && chat.ownerId !== user.id) {
      return fail(res, 403, '只有群主能给别的成员设置群昵称');
    }
    const alias = str(body.alias, 32).replace(/\s+/g, ' ').trim();
    if (!chat.aliases) chat.aliases = {};
    if (alias) chat.aliases[targetId] = alias;
    else delete chat.aliases[targetId];
    saveChats();
    /* 群里其他人立刻看到新的群昵称（消息里那个名字跟着变） */
    chat.memberIds.forEach((id) => {
      sendTo(id, { type: 'group-alias', chatId: chat.id, userId: targetId, alias });
    });
    ok(res, { alias, userId: targetId,
      name: alias || displayNameFor(user.id, findUser(targetId)) });
    return;
  }

  /* ================= 群管理（群名称 / 群公告 / 群屏蔽 / 群踢人 / 群解散 / 退群）================= */

  /* 群二维码：给当前群生成一个邀请码（不带状态，随时可重算），扫进来直接进群 */
  /* 我的二维码：每个人一张，扫了能加好友 */
  if (parts[0] === 'me' && parts[1] === 'qrcode' && method === 'GET') {
    const code = userCode(user.username);
    /* 二维码里写公网域名（不是服务器内网 IP）：外面用相机扫也能打开这个链接 */
    const url = payBaseUrl(req) + '/add.html?u=' + encodeURIComponent(code);
    const enc = QR.encode(url);
    ok(res, {
      code: code, url: url,
      rows: enc ? enc.modules.map((r) => r.join('')) : [], size: enc ? enc.size : 0,
      user: publicUser(user)
    });
    return;
  }

  /* 扫到别人的个人二维码：先看看是谁 */
  if (parts[0] === 'user-by-code' && method === 'GET') {
    const u = findUserByName(usernameFromUserCode(str(query.get('code'), 80)));
    if (!u) return fail(res, 404, '这个二维码无效或者过期了');
    ok(res, { user: publicUser(u) });
    return;
  }

  /* 扫到别人的个人二维码：直接加好友 */
  /* 扫到别人的个人二维码：只「看一眼是谁」，不直接加好友 —— 和微信一样先跳资料页 */
  if (parts[0] === 'user-by-code' && method === 'POST') {
    const body = await readBody(req);
    const u = findUserByName(usernameFromUserCode(str(body.code, 80)));
    if (!u) return fail(res, 404, '这个二维码无效或者过期了');
    if (u.id === user.id) return fail(res, 422, '这是你自己的二维码');
    if (!userPrivacy(u).addByQR) return fail(res, 403, '对方关闭了「通过二维码添加我」');
    const exist = friendshipBetween(user.id, u.id);
    const relation = !exist ? 'none'
      : (exist.status === 'accepted' ? 'friend'
        : (exist.fromId === user.id ? 'pending' : 'incoming'));
    ok(res, { user: publicUser(u), relation });
    return;
  }
  if (parts[0] === 'add-by-code' && method === 'POST') {
    const body = await readBody(req);
    const u = findUserByName(usernameFromUserCode(str(body.code, 80)));
    if (!u) return fail(res, 404, '这个二维码无效或者过期了');
    if (u.id === user.id) return fail(res, 422, '这是你自己的二维码');
    /* 隐私：对方关掉「通过二维码添加我」就不给加 */
    if (!userPrivacy(u).addByQR) return fail(res, 403, '对方关闭了「通过二维码添加我」');
    const exist = friendshipBetween(user.id, u.id);
    if (exist) {
      if (exist.status === 'accepted') return ok(res, { already: true, user: publicUser(u) });
      if (exist.fromId === user.id) return ok(res, { pending: true, user: publicUser(u) });
      /* 对方之前加过我：互加，直接变好友 */
      exist.status = 'accepted';
      exist.respondedAt = now();
      saveFriendships();
      const c2 = openChatForFriendship(exist.fromId, exist.toId);
      sendTo(u.id, { type: 'friend', action: 'accepted', user: publicUser(user) });
      sendTo(exist.fromId, { type: 'chat', chatId: c2 ? c2.id : '' });
      sendTo(exist.toId, { type: 'chat', chatId: c2 ? c2.id : '' });
      ok(res, { accepted: true, user: publicUser(u) });
      return;
    }
    const f = { id: uid('f'), fromId: user.id, toId: u.id, status: 'pending', createdAt: now() };
    db.friendships.push(f);
    saveFriendships();
    sendTo(u.id, { type: 'friend', action: 'request', requestId: f.id, user: publicUser(user) });
    ok(res, { sent: true, user: publicUser(u) });
    return;
  }

  if (parts[0] === 'chats' && parts[2] === 'invite' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (chat.type !== 'group') return fail(res, 422, '只有群聊有群二维码');
    const code = inviteCode(chat.id);
    /* 同上：写公网域名，别写内网 IP */
    const url = payBaseUrl(req) + '/join.html?c=' + encodeURIComponent(code);
    const enc = QR.encode(url);
    ok(res, {
      code: code, url: url, svg: QR.svg(url, 7),
      rows: enc ? enc.modules.map((r) => r.join('')) : [], size: enc ? enc.size : 0
    });
    return;
  }

  /* 扫码进群：/join.html 打开后调它（没登录会先去登录） */
  if (parts[0] === 'join' && method === 'POST') {
    const body = await readBody(req);
    const code = str(body.code, 60);
    const chatId = chatIdFromInvite(code);
    if (!chatId) return fail(res, 404, '这个群二维码无效或者过期了');
    const chat = db.chats.find((c) => c.id === chatId && c.type === 'group');
    if (!chat || chat.dismissed) return fail(res, 404, '这个群已经不在了');
    if (chat.memberIds.includes(user.id)) return ok(res, { joined: false, already: true, chat: chatSummary(chat, user.id) });
    if (chat.memberIds.length >= 200) return fail(res, 422, '群人数满了');
    chat.memberIds.push(user.id);
    buildGroupAvatar(chat);
    const sys = pushSystemMessage(chat, user.nickname + ' 通过群二维码加入了群聊');
    chat.memberIds.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
    saveChats();
    ok(res, { joined: true, chat: chatSummary(chat, user.id) });
    return;
  }

  /* 群禁言：全员禁言 / 单独禁言某个人（只有群主能开） */
  if (parts[0] === 'chats' && parts[2] === 'muteall' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (chat.type !== 'group') return fail(res, 422, '只有群聊能禁言');
    if (chat.ownerId !== user.id) return fail(res, 403, '只有群主能开启全员禁言');
    const body = await readBody(req);
    chat.muteAll = body.on !== false;
    const sys = pushSystemMessage(chat, chat.muteAll ? '群主开启了全员禁言' : '群主关闭了全员禁言');
    chat.memberIds.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
    saveChats();
    ok(res, { muteAll: chat.muteAll });
    return;
  }
  if (parts[0] === 'chats' && parts[2] === 'mutemember' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (chat.type !== 'group') return fail(res, 422, '只有群聊能禁言');
    if (chat.ownerId !== user.id) return fail(res, 403, '只有群主能禁言成员');
    const body = await readBody(req);
    const target = findUser(str(body.userId, 40));
    if (!target || !chat.memberIds.includes(target.id)) return fail(res, 404, '这个人不在群里');
    if (target.id === user.id) return fail(res, 422, '群主不用禁言自己');
    const set = new Set(chat.muteMembers || []);
    if (body.muted === false) set.delete(target.id); else set.add(target.id);
    chat.muteMembers = Array.from(set);
    saveChats();
    sendToChat(chat, { type: 'chat', action: 'updated', chat: chatSummary(chat, user.id) });
    ok(res, { muted: chat.muteMembers.includes(target.id) });
    return;
  }

  // 改群名称、群公告：只有群主能改
  if (parts[0] === 'chats' && parts[2] === 'info' && method === 'PATCH') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (chat.type !== 'group') return fail(res, 422, '只有群聊才有群名称和群公告');
    if (chat.ownerId !== user.id) return fail(res, 403, '只有群主能改群名称和群公告');
    const body = await readBody(req);
    let changed = false;
    if (body.name !== undefined) {
      const n = str(body.name, 30);
      if (!n) return fail(res, 422, '群名称不能为空');
      chat.name = n;
      changed = true;
    }
    if (body.announce !== undefined) {
      chat.announce = str(body.announce, 500);
      changed = true;
    }
    if (!changed) return fail(res, 422, '没有要修改的内容');
    saveChats();
    chat.memberIds.forEach((id) => sendTo(id, { type: 'chat', action: 'updated', chat: chatSummary(chat, id) }));
    ok(res, { name: chat.name, announce: chat.announce || '' });
    return;
  }

  // 消息免打扰（群屏蔽）：每个人自己设，别人不受影响
  /* CHRIS_BURN_V1 阅后即焚开关（聊天信息页里那个开关） */
  if (parts[0] === 'chats' && parts[2] === 'burn' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');
    const body = await readBody(req);
    chat.burn = body.on !== false;
    saveChats();
    chat.memberIds.forEach((id) => sendTo(id, { type: 'chat', action: 'updated', chat: chatSummary(chat, id) }));
    ok(res, { burn: !!chat.burn });
    return;
  }

  /* CHRIS_BURN_V1 扫一遍阅后即焚：
     —— 别人发给我的、还没销毁的：标记成「我已看过」；看过满 8 秒的直接删掉（双方都没了）
     —— 我发给别人的：只有对方也看过、并且满 8 秒才删（我这边也会消失，和微信一样）
     返回这次真正销毁掉的消息 id，客户端收到就把它从列表里去掉。 */
  if (parts[0] === 'chats' && parts[2] === 'burn-sweep' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');
    if (!chat.burn) { ok(res, { ids: [] }); return; }
    const list = loadMessages(chat.id);
    const nowTs = Date.now();
    const HOLD = BURN_HOLD_MS;      // CHRIS_BURN_V1 看过 20 秒后焚毁（2026-10-13 用户定）
    const gone = [];
    let changed = false;
    list.forEach((m) => {
      if (!m.burn) return;
      if (m.senderId !== user.id) {
        if (!m.seenBy) m.seenBy = [];
        if (m.seenBy.indexOf(user.id) < 0) { m.seenBy.push(user.id); m.seenAt = nowTs; changed = true; }
      }
      /* 谁扫都行：只要**接收方**的已读游标已经过了这一条，就算看过了。
         （发送方来扫也能据此开始计时，不用等对方那台手机也来扫一遍。） */
      if (!m.seenAt) {
        const read = chat.memberIds.some((id) => id !== m.senderId
          && ((db.reads[id] && db.reads[id][chat.id]) || 0) >= (m.seq || 0));
        if (read) { m.seenAt = nowTs; changed = true; }
      }
      /* 看过满 1 分钟就烧（不再要求「所有人」都扫过一遍：以前发送方也得来扫一次，
         两个人都不动就永远不烧 —— 用户报「阅后即焚没生效」就是这个）。
         单聊里 seenBy 就是对方；群里以**第一个看过的人**开始计时。 */
      /* CHRIS_BURN_LOG_V1 两条销毁条件：
         ① 有人看过（seenAt）并且满 1 分钟；
         ② 兜底：这条消息本身已经超过 5 分钟（对方是旧版本、压根不会上报「已读」时，
            否则会永远留在屏幕上，用户报的「消息还是不会消失」就是这个）。 */
      const born = Date.parse(m.createdAt) || 0;
      if ((m.seenAt && nowTs - m.seenAt >= HOLD) || (born && nowTs - born > 5 * 60 * 1000)) gone.push(m.id);
    });
    if (gone.length) {
      /* CHRIS_BURN_FIX_V1 ⚠ 必须**原地删**：loadMessages 返回的就是 messageCache 里那个数组，
         以前这里 list.filter(...) 生成一个新数组写进文件 —— 缓存里那 3 条还在，
         于是每次扫描都「销毁=3」，客户端就一直收到焚毁事件（用户报的「一直跳、消息还在」就是这个）。
         原地 splice 之后缓存、文件、以后每次读都是干净的。 */
      const goneSet = {};
      gone.forEach((id) => { goneSet[id] = 1; });
      for (let i = list.length - 1; i >= 0; i--) {
        if (goneSet[list[i].id]) list.splice(i, 1);
      }
      saveMessagesFile(chat.id, list);
      chat.memberIds.forEach((id) => sendTo(id, { type: 'burn', chatId: chat.id, ids: gone }));
    } else if (changed) {
      saveMessagesFile(chat.id, list);      // CHRIS_BURN_V1
    }
    try {
      callTrace('burn-sweep ' + chat.id + ' by ' + (user.nickname || user.username)
        + ' 条数=' + list.length + ' 销毁=' + gone.length + ' 标记已读=' + changed);
    } catch (e) { }
    ok(res, { ids: gone });
    return;
  }

  if (parts[0] === 'chats' && parts[2] === 'mute' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');
    const body = await readBody(req);
    const set = new Set(chat.mutedFor || []);
    if (body.muted === false) set.delete(user.id); else set.add(user.id);
    chat.mutedFor = Array.from(set);
    saveChats();
    sendTo(user.id, { type: 'chat', action: 'updated', chat: chatSummary(chat, user.id) });
    ok(res, { muted: chat.mutedFor.includes(user.id) });
    return;
  }

  /* 群加人：群里任何一个成员都能拉人进来（微信默认也是这样），群上限 500。
     注意路径不能用 invite —— 那个已经被「群二维码/邀请码」占用了。 */
  if (parts[0] === 'chats' && parts[2] === 'add-members' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (chat.type !== 'group') return fail(res, 422, '只有群聊能加人');
    if (chat.dismissed) return fail(res, 422, '这个群已经解散了');
    const body = await readBody(req);
    const want = (Array.isArray(body.userIds) ? body.userIds : []).map((x) => String(x)).slice(0, 50);
    if (!want.length) return fail(res, 422, '先选要拉进来的人');

    const MAX_MEMBERS = 500;
    const added = [];
    let skipped = 0;
    for (const id of want) {
      if (chat.memberIds.includes(id)) { skipped += 1; continue; }
      const u = findUser(id);
      if (!u || u.banned) { skipped += 1; continue; }
      /* 跟拉人的这个人互相拉黑就不放进群 */
      if (chatBlockedBetween(user.id, u.id)) { skipped += 1; continue; }
      if (chat.memberIds.length >= MAX_MEMBERS) break;
      chat.memberIds.push(u.id);
      added.push(u);
    }
    if (!added.length) return fail(res, 409, '这几个人都已经在群里了');

    chat.dismissed = false;
    if (Array.isArray(chat.hiddenFor) && chat.hiddenFor.length) chat.hiddenFor = [];
    buildGroupAvatar(chat);
    const names = added.map((u) => u.nickname || u.username).join('、');
    const sys = pushSystemMessage(chat, user.nickname + ' 邀请 ' + names + ' 加入了群聊');
    chat.memberIds.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
    /* 新进来的人：推一下「你被拉进这个群了」，App 收到就刷新会话列表 */
    added.forEach((u) => sendTo(u.id, { type: 'chat', action: 'added', chatId: chat.id, chat: chatSummary(chat, u.id) }));
    saveChats();
    ok(res, {
      memberCount: chat.memberIds.length,
      added: added.map((u) => ({ id: u.id, name: u.nickname || u.username })),
      skipped
    });
    return;
  }

  // 群踢人：群主把某个成员移出群聊
  if (parts[0] === 'chats' && parts[2] === 'kick' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (chat.type !== 'group') return fail(res, 422, '只有群聊能移出成员');
    if (chat.ownerId !== user.id) return fail(res, 403, '只有群主能移出成员');
    const body = await readBody(req);
    const target = findUser(str(body.userId, 40));
    if (!target || !chat.memberIds.includes(target.id)) return fail(res, 404, '这个人不在群里');
    if (target.id === user.id) return fail(res, 422, '群主不能移出自己，想散就直接解散群');
    chat.memberIds = chat.memberIds.filter((id) => id !== target.id);
    chat.mutedFor = (chat.mutedFor || []).filter((id) => id !== target.id);
    chat.pinnedFor = (chat.pinnedFor || []).filter((id) => id !== target.id);
    buildGroupAvatar(chat);
    const sys = pushSystemMessage(chat, target.nickname + ' 被移出了群聊');
    chat.memberIds.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
    sendTo(target.id, { type: 'chat', action: 'removed', chatId: chat.id });
    saveChats();
    ok(res, { memberCount: chat.memberIds.length });
    return;
  }

  // 退出群聊：群主退群就顺位把群主交给下一个人
  if (parts[0] === 'chats' && parts[2] === 'leave' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    const others = chat.memberIds.filter((id) => id !== user.id);
    if (!others.length) {
      chat.memberIds = [];
      chat.dismissed = true;
      saveChats();
      ok(res, { left: true, dismissed: true });
      return;
    }
    if (chat.ownerId === user.id) chat.ownerId = others[0];
    chat.memberIds = others;
    chat.mutedFor = (chat.mutedFor || []).filter((id) => id !== user.id);
    chat.pinnedFor = (chat.pinnedFor || []).filter((id) => id !== user.id);
    buildGroupAvatar(chat);
    const sys = pushSystemMessage(chat, user.nickname + ' 退出了群聊');
    others.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
    sendTo(user.id, { type: 'chat', action: 'removed', chatId: chat.id });
    saveChats();
    ok(res, { left: true, ownerId: chat.ownerId });
    return;
  }

  // 解散群聊：只有群主
  if (parts[0] === 'chats' && parts[2] === 'dismiss' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat) return fail(res, 404, '会话不存在');
    if (!chat.memberIds.includes(user.id)) return fail(res, 403, '你不在这个会话里');
    if (chat.type !== 'group') return fail(res, 422, '只有群聊能解散');
    if (chat.ownerId !== user.id) return fail(res, 403, '只有群主能解散群聊');
    const members = chat.memberIds.slice();
    const sys = pushSystemMessage(chat, '群主解散了该群聊');
    members.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
    chat.memberIds = [];
    chat.dismissed = true;
    saveChats();
    members.forEach((id) => sendTo(id, { type: 'chat', action: 'removed', chatId: chat.id }));
    ok(res, { dismissed: true });
    return;
  }

  // 查找聊天记录：在服务器上翻这个会话的历史（不只是手机里加载的那几十条）
  if (parts[0] === 'chats' && parts[2] === 'search' && method === 'GET') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');
    const q = str(query.get('q'), 40);
    if (!q) return ok(res, { messages: [] });
    const clearedSeq = ((db.cleared || {})[user.id] || {})[chat.id] || 0;
    const kw = q.toLowerCase();
    const hit = loadMessages(chat.id)
      .filter((m) => m.seq > clearedSeq && !m.recalled && m.kind !== 'system'
        && String(m.content || '').toLowerCase().indexOf(kw) >= 0)
      .slice(-60)
      .reverse();
    ok(res, {
      messages: hit.map((m) => {
        const sender = findUser(m.senderId) || {};
        return {
          id: m.id, seq: m.seq, kind: m.kind, content: m.content, createdAt: m.createdAt,
          senderId: m.senderId, senderName: sender.nickname || ''
        };
      })
    });
    return;
  }

  // 清空聊天记录：只清自己这边的，别人不受影响
  if (parts[0] === 'chats' && parts[2] === 'clear' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');
    const messages = loadMessages(chat.id);
    const lastSeq = messages.length ? messages[messages.length - 1].seq : 0;
    if (!db.cleared[user.id]) db.cleared[user.id] = {};
    db.cleared[user.id][chat.id] = lastSeq;
    if (!db.reads[user.id]) db.reads[user.id] = {};
    db.reads[user.id][chat.id] = lastSeq;
    saveReads();
    ok(res, { cleared: lastSeq });
    return;
  }

  // 标为未读：把已读位置退回一条，这样最后一条又算未读（QQ / 微信左滑里的「标为未读」）
  if (parts[0] === 'chats' && parts[2] === 'unread' && method === 'POST') {
    const chat = db.chats.find((c) => c.id === parts[1]);
    if (!chat || !chat.memberIds.includes(user.id)) return fail(res, 404, '会话不存在');
    const messages = loadMessages(chat.id);
    const lastSeq = messages.length ? messages[messages.length - 1].seq : 0;
    if (!db.reads[user.id]) db.reads[user.id] = {};
    db.reads[user.id][chat.id] = Math.max(0, lastSeq - 1);
    saveReads();
    chat.flaggedUnread = Array.from(new Set((chat.flaggedUnread || []).concat([user.id])));
    saveChats();
    ok(res, { unread: unreadCount(user.id, chat) });
    return;
  }

  if (parts[0] === 'messages' && parts[2] === 'recall' && method === 'POST') {
    const body = await readBody(req);
    const result = recallMessage(user, body.chatId, parts[1]);
    if (result.error) return fail(res, 422, result.error);
    ok(res, { message: result.message });
    return;
  }

  /* ------------------------------------------------ 设备确认登录：确认方 */
  if (parts[0] === 'pair' && parts[1] === 'approve' && method === 'POST') {
    const body = await readBody(req);
    prunePairCodes();
    const code = str(body.code, 10);
    const rec = pairCodes.get(code);
    if (!rec) return fail(res, 404, '登录码已过期，让那台设备刷新一下');
    rec.userId = user.id;
    rec.approvedName = user.nickname;
    ok(res, { approved: true, code, user: publicUser(user) });
    return;
  }

  /* -------------------------------------------------------------- 朋友圈 */

  if (parts[0] === 'moments' && method === 'POST' && parts[1] === 'seen') {
    db.momentViews[user.id] = now();
    saveMomentViews();
    ok(res, { unread: 0 });
    return;
  }

  /* 补机器人：登录后调一次，保证「AI 助手 / 贾维斯AI / 星联世界」一定在
     （哪怕账号是刚注册的、或者服务器还没重启过） */
  if (parts[0] === 'bots' && parts[1] === 'ensure' && method === 'POST') {
    ensureBots();
    try { ensureSysChat(currentUser(req)); } catch (e) {}
    const hello = {
      ai: '你好，我是 AI 助手，只负责这个 App 的使用问题 👋\n哪找不到、怎么操作都可以问我，比如「怎么换头像」「朋友圈在哪发」。',
      housekeeper: '您好，我是 AI 助手，您的管家，随时为您效劳。\n整个微信里的事都能吩咐我：\n· 给张三发消息 你好　· 建个群 张三 李四　· 加好友 微信号\n· 提醒我 8:30 开会　· 天气 上海　· 记账 午饭 25 / 账本\n· 发朋友圈 今天天气真好 / 写条朋友圈 加班 / 改签名 岁月静好\n· 给张三的朋友圈点赞　· 评论张三的朋友圈：好看\n· 置顶/免打扰/删掉 张三　· 清空和张三的聊天记录\n· 我和张三聊了什么 / 找张三说过 合同\n· 给张三转 50　· 我的账单　· 谁在线　· 余额',
      qqnews: '你好，我是星联世界，只报新闻～\n发「新闻」看今天的热点，或者说「讲讲第 2 条」让我讲细一点。'
    };
    const made = [];
    /* 在线客服（service）不算：它的会话只在你点「联系客服」时才建 */
    db.users.filter((u) => u.bot && !u.service).forEach((bot) => {
      const f = friendshipBetween(user.id, bot.id);
      if (!f) db.friendships.push({ id: uid('f'), fromId: bot.id, toId: user.id, status: 'accepted', createdAt: now() });
      else if (f.status !== 'accepted') f.status = 'accepted';
      let chat = directChatBetween(user.id, bot.id);
      if (!chat) chat = createDirectChat(user.id, bot.id);
      const set = new Set(chat.pinnedFor || []);
      if (bot.username !== 'qqnews' && !set.has(user.id)) { set.add(user.id); chat.pinnedFor = Array.from(set); }
      const msgs = loadMessages(chat.id);
      if (!msgs.some((m) => m.senderId === bot.id)) {
        try { deliverMessage(bot, chat.id, 'text', hello[bot.username] || '你好，我是机器人', null); } catch (e) { }
      }
      made.push(bot.username);
    });
    saveFriendships(); saveChats();
    ok(res, { bots: made });
    return;
  }

  if (parts[0] === 'news' && method === 'GET') {
    /* 一个源：/api/news?source=qq&limit=30
       只拿频道列表（客户端首屏画上面那排 tab 用，不拉内容）：/api/news?channels=1
       不带 source 的老调用（AI 机器人 / 旧包）还是走腾讯那条 */
    if (query.get('channels')) { ok(res, { channels: NEWS_CHANNELS }); return; }
    const want = str(query.get('source'), 20) || 'qq';
    /* 一次多抓一些（最多 50 条）留在缓存里，然后按 offset 切一批给客户端 ——
       「换一批」就是把 offset 往后挪，挪到底再从头上（榜单就那么多条）。 */
    const limit = Math.max(5, Math.min(40, Number(query.get('limit')) || 20));
    const offset = Math.max(0, Number(query.get('offset')) || 0);
    const r = await fetchNews(want, 50);
    const all = r.list || [];
    let list = all.slice(offset, offset + limit);
    if (!list.length) list = all.slice(0, limit);
    ok(res, { list, source: r.source, updatedAt: r.at, channels: NEWS_CHANNELS, total: all.length, offset });
    return;
  }

  /* ---------------- 公众号（我们自己的） ----------------
     通讯录里的「公众号」列表 / 某个号的主页 / 文章详情 / 订阅·取消订阅 */
  /* ---------------- 群会议（多人视频）：进 / 出 / 查房间 ----------------
     房号 = 群会话 id。媒体由 TRTC 转发（同房号即同房间），这里只管「谁在房里」+ 给群里推提示。
     微信的逻辑：发起后群里出现一张通话卡片；点卡片的人进同一间房；有人进出都会有提示。 */
  if (parts[0] === 'call' && parts[1] === 'meeting' && (method === 'GET' || method === 'POST')) {
    const body = method === 'POST' ? await readBody(req) : {};
    const chatId = str(method === 'POST' ? body.chatId : query.get('chatId'), 60);
    const chat = db.chats.find((c) => c.id === chatId);
    if (!chat || chat.type !== 'group' || !chat.memberIds.includes(user.id)) {
      return fail(res, 404, method === 'GET' ? '群不存在' : '只有群聊能开群会议');
    }
    let m = meetingOf(chatId);
    if (method === 'GET') {
      return ok(res, {
        room: chatId,
        members: m.members.map((id) => publicUserBrief(findUser(id), user.id)).filter(Boolean),
        count: m.members.length, startedAt: m.startedAt, locked: m.locked, ownerId: m.ownerId,
        online: m.members.includes(user.id)
      });
    }
    const action = String(body.action || 'join') === 'leave' ? 'leave' : 'join';
    if (action === 'join') {
      if (m.locked && m.ownerId !== user.id && !m.members.includes(user.id)) return fail(res, 403, '会议已被锁定');
      if (!m.members.includes(user.id)) m.members.push(user.id);
      if (!m.startedAt) m.startedAt = Date.now();
      if (!m.ownerId) m.ownerId = user.id;      // 第一个人就是房主（微信也是发起人当房主）
    } else {
      m.members = m.members.filter((id) => id !== user.id);
      if (!m.members.length) m = { members: [], startedAt: 0, locked: false, ownerId: '' };
    }
    saveMeetingOf(chatId, m);
    chat.memberIds.forEach((id) => sendTo(id, {
      type: 'meeting', chatId: chatId, room: chatId, action: action,
      user: publicUser(user), count: m.members.length,
      members: m.members.slice(), startedAt: m.startedAt, locked: !!m.locked, ownerId: m.ownerId
    }));
    return ok(res, { room: chatId, action: action, count: m.members.length,
                     startedAt: m.startedAt, locked: !!m.locked, ownerId: m.ownerId });
  }

  if (parts[0] === 'oa' && parts[1] === 'list' && method === 'GET') {
    const oa = readOA();
    const follows = readOAFollows().filter((f) => f.userId === user.id);
    const mine = new Set(follows.map((f) => f.accountId));
    const list = oa.accounts.filter((a) => a.enabled !== false).map((a) => {
      const arts = oa.articles.filter((x) => x.accountId === a.id);
      const last = arts.length ? arts[arts.length - 1] : null;
      return {
        id: a.id, name: a.name || '', avatar: a.avatar || '', bio: a.bio || '',
        type: a.type || 'subscribe', following: mine.has(a.id),
        articleCount: arts.length, lastAt: last ? last.createdAt : (a.createdAt || '')
      };
    }).sort((x, y) => String(y.lastAt).localeCompare(String(x.lastAt)));
    ok(res, { accounts: list });
    return;
  }

  if (parts[0] === 'oa' && parts[1] === 'account' && method === 'GET') {
    const id = str(query.get('id'), 40);
    const oa = readOA();
    const acc = oa.accounts.find((a) => a.id === id);
    if (!acc) return fail(res, 404, '这个公众号不存在');
    const articles = oa.articles
      .filter((x) => x.accountId === acc.id)
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, 60)
      .map((a) => ({
        id: a.id, title: a.title || '', summary: a.summary || '', cover: a.cover || '',
        createdAt: a.createdAt, reads: a.reads || 0
      }));
    const following = readOAFollows().some((f) => f.userId === user.id && f.accountId === acc.id);
    ok(res, {
      account: {
        id: acc.id, name: acc.name || '', avatar: acc.avatar || '', bio: acc.bio || '',
        type: acc.type || 'subscribe', following
      },
      articles
    });
    return;
  }

  if (parts[0] === 'oa' && parts[1] === 'article' && method === 'GET') {
    const id = str(query.get('id'), 40);
    const oa = readOA();
    const art = oa.articles.find((a) => a.id === id);
    if (!art) return fail(res, 404, '这篇文章不在了');
    art.reads = (art.reads || 0) + 1;          // 阅读数 +1
    saveOA(oa);
    const acc = oa.accounts.find((a) => a.id === art.accountId) || { id: '', name: '' };
    const following = readOAFollows().some((f) => f.userId === user.id && f.accountId === acc.id);
    ok(res, {
      article: {
        id: art.id, title: art.title || '', summary: art.summary || '', cover: art.cover || '',
        author: art.author || '', content: art.content || '', createdAt: art.createdAt,
        reads: art.reads || 0, originalUrl: art.originalUrl || ''
      },
      account: {
        id: acc.id || '', name: acc.name || '', avatar: acc.avatar || '',
        bio: acc.bio || '', type: acc.type || 'subscribe', following
      }
    });
    return;
  }

  if (parts[0] === 'oa' && parts[1] === 'follow' && method === 'POST') {
    const body = await readBody(req);
    const acc = readOA().accounts.find((a) => a.id === str(body.accountId, 40));
    if (!acc) return fail(res, 404, '这个公众号不存在');
    const on = body.follow !== false;
    if (on) {
      const r = oaFollow(user, acc);
      if (r && r.error) return fail(res, 422, r.error);
    } else {
      saveOAFollows(readOAFollows().filter((f) => !(f.userId === user.id && f.accountId === acc.id)));
      /* 取消订阅：那条会话从列表里拿掉（号还在公众号列表里，随时能再订阅） */
      const isSub = (acc.type || 'subscribe') === 'subscribe';
      const bot = isSub ? findBot('oa_digest') : findBot(oaUsername(acc.id));
      const chat = bot ? directChatBetween(user.id, bot.id) : null;
      if (chat) {
        chat.hiddenFor = Array.from(new Set((chat.hiddenFor || []).concat([user.id])));
        saveChats();
        sendTo(user.id, { type: 'chat', action: 'removed', chatId: chat.id });
      }
    }
    ok(res, { following: on });
    return;
  }

  /* 朋友圈「消息列表」（微信右上角那个小信封）：
     GET  /api/moments/notices        谁赞了/评论了我（新→旧）
     POST /api/moments/notices/seen   点开这一页 = 看过，未读数清零 */
  if (parts[0] === 'moments' && parts[1] === 'notices' && parts.length === 3
      && parts[2] === 'seen' && method === 'POST') {
    db.momentNoticeSeen[user.id] = now();
    saveMomentNotices();
    ok(res, { unread: 0 });
    return;
  }

  if (parts[0] === 'moments' && parts[1] === 'notices' && parts.length === 2 && method === 'GET') {
    const limit = Math.min(100, Math.max(1, Number(query.get('limit')) || 60));
    const mine = db.momentNotices.filter((r) => r.toUserId === user.id);
    /* 动态被删掉的那种通知不再显示（微信删了动态，消息列表里那条也点不开） */
    const rows = mine.slice(-limit).reverse()
      .filter((r) => db.moments.some((m) => m.id === r.momentId))
      .map((r) => publicMomentNotice(r, user.id));
    ok(res, { items: rows, unread: momentNoticeUnread(user.id), total: mine.length });
    return;
  }

  if (parts[0] === 'moments' && method === 'GET' && parts.length === 1) {
    const limit = Math.min(50, Math.max(1, Number(query.get('limit')) || 20));
    const before = str(query.get('before'), 40);
    const beforeId = str(query.get('beforeId'), 40);
    const onlyUser = str(query.get('userId'), 40);
    /* 陌生人的朋友圈不给看：只能看自己或好友的 */
    if (onlyUser && onlyUser !== user.id && !friendSetCached(user.id).has(onlyUser)) {
      /* 隐私：对方开了「允许陌生人查看朋友圈」就给看（但只给看最近 10 条） */
      const other = findUser(onlyUser);
      if (!other || !userPrivacy(other).strangerMoments) return fail(res, 403, '只能看好友的朋友圈');
    }
    const audience = momentAudience(user.id);
    const audienceSet = new Set(audience);      // 同上：数组 includes 在几千条动态时会拖死服务器
    /* 谁可以看：公开 / 私密（只有自己）/ 部分可见 / 不给谁看（对应功能清单里的那一行） */
    let list = db.moments.filter((m) => audienceSet.has(m.authorId) && momentVisibleTo(m, user.id));
    /* 朋友权限（微信「设置备注和标签 → 朋友权限」那一栏）：
       · 我设了「不看他（她）的朋友圈」→ 他的动态不在我的列表里
       · 他设了「不让他（她）看我」或者拉黑了我 → 我也看不到 */
    const hiddenForMe = (authorId) => {
      const mine = metaOf(user.id, authorId);
      if (mine.block === true || mine.noMoments === true) return true;
      const theirs = metaOf(authorId, user.id);
      return theirs.block === true || theirs.hideMyMoments === true;
    };
    list = list.filter((m) => !hiddenForMe(m.authorId));
    /* 朋友圈可见范围（微信那套）：作者设了「最近三天 / 最近半年」，
       别人就只能看到这个范围内的；**自己看自己永远是全部**。
       范围按作者算一次（同一个人一页里可能好几条，别每条都重算）。 */
    const rangeCutCache = {};
    const rangeCut = (authorId) => {
      if (authorId in rangeCutCache) return rangeCutCache[authorId];
      const rg = String(userPrivacy(findUser(authorId) || {}).momentsRange || 'all');
      const cut = (rg === '3d' || rg === '6m')
        ? Date.now() - (rg === '3d' ? 3 : 183) * 24 * 3600 * 1000
        : 0;
      rangeCutCache[authorId] = cut;
      return cut;
    };
    list = list.filter((m) => {
      if (m.authorId === user.id) return true;
      const cut = rangeCut(m.authorId);
      if (!cut) return true;
      const t = Date.parse(m.createdAt);
      return !isFinite(t) || t >= cut;
    });
    if (onlyUser) list = list.filter((m) => m.authorId === onlyUser);
    /* 排序要稳定：时间一样时再按 id 排。
       否则「同一毫秒发的几十条」在翻页时会被整段跳过（时间戳当游标最怕这个）。 */
    list = list.slice().sort((a, b) => {
      /* 置顶的动态永远在最上面（自己置顶的），其余按时间倒序 —— 微信时间轴就是这个规矩 */
      const pa = a.pinned === true ? 1 : 0, pb = b.pinned === true ? 1 : 0;
      if (pa !== pb && !before) return pb - pa;
      const c = String(b.createdAt).localeCompare(String(a.createdAt));
      return c !== 0 ? c : String(b.id).localeCompare(String(a.id));
    });
    if (before) {
      list = beforeId
        ? list.filter((m) => String(m.createdAt) < before ||
            (String(m.createdAt) === before && String(m.id) < beforeId))
        : list.filter((m) => String(m.createdAt) < before);      // 老客户端没传 id 时还按老规矩
    }
    const slice = list.slice(0, limit);
    const target = onlyUser ? memberProfile(findUser(onlyUser), user.id) : null;
    ok(res, {
      moments: slice.map((m) => visibleMoment(m, user.id)),
      hasMore: list.length > slice.length,
      unread: momentUnread(user.id),
      /* 朋友圈「消息列表」的未读数（右上角小信封上的红点） */
      noticeUnread: momentNoticeUnread(user.id),
      total: list.length,
      target,
      /* 看别人的朋友圈时把这个人的可见范围一起给客户端（all / 3d / 6m）——
         App 会用它显示「朋友仅展示最近三天的朋友圈」那句提示 */
      range: (onlyUser && onlyUser !== user.id)
        ? String(userPrivacy(findUser(onlyUser) || {}).momentsRange || 'all')
        : 'all'
    });
    return;
  }

  if (parts[0] === 'moments' && method === 'POST' && parts.length === 1) {
    if (!momentRateAllow(user.id)) {
      return fail(res, 429, '发朋友圈太频繁了（1 分钟最多 20 条）');
    }
    /* 风控：被临时限制的账号先挡住 */
    const moBlocked = riskBlocked(user);
    if (moBlocked) return fail(res, 429, '账号功能被临时限制，还有 ' + moBlocked + ' 分钟（如有疑问请联系管理员）');
    /* 违规账号（或风控分偏高）：朋友圈也不让发（含图片/视频那条动态） */
    const moWhy = mediaBlockedReason(user);
    if (moWhy) return fail(res, 403, moWhy);
    const body = await readBody(req);
    const content = str(body.content, 1000);
    const images = (Array.isArray(body.images) ? body.images : [])
      .map((x) => safeImageRef(str(x, 2000))).filter(Boolean).slice(0, 9);
    /* 视频（微信：一条动态要么九张图，要么一条视频） */
    const video = safeImageRef(str(body.video, 2000)) || '';
    const videoCover = safeImageRef(str(body.videoCover, 2000)) || '';
    /* 每张图的宽高（客户端上传时带上）：列表那边一上来就能按真实比例把框画好，
       不会再「先 4:3、加载完跳一下」（用户反馈的尺寸跳变） */
    const imageSizes = {};
    {
      const raw = (body.imageSizes && typeof body.imageSizes === 'object') ? body.imageSizes : {};
      images.forEach((pth) => {
        const v = raw[pth];
        if (Array.isArray(v) && v.length === 2) {
          const w = Math.min(20000, Math.max(0, Number(v[0]) || 0));
          const h = Math.min(20000, Math.max(0, Number(v[1]) || 0));
          if (w > 0 && h > 0) imageSizes[pth] = [w, h];
        }
      });
    }
    if (!content && !images.length && !video) return fail(res, 422, '写点什么，或者发张图/视频');
    const moment = {
      id: uid('mo'),
      authorId: user.id,
      content,
      images,
      imageSizes,
      video,
      videoCover,
      videoSeconds: Math.min(900, Math.max(0, Number(body.videoSeconds) || 0)),
      videoW: Math.min(8000, Math.max(0, Number(body.videoW) || 0)),
      videoH: Math.min(8000, Math.max(0, Number(body.videoH) || 0)),
      /* 所在位置（微信发表页那一行；不填就是空的，不发 */
      location: str(body.location, 40),
      /* 可见范围：public（好友可见，默认）/ private（仅自己）/ partial（只给这些人看）/ exclude（不给这些人看） */
      visibility: ['private', 'partial', 'exclude'].includes(String(body.visibility)) ? String(body.visibility) : 'public',
      visibleTo: (Array.isArray(body.visibleTo) ? body.visibleTo : []).map((x) => str(x, 40)).filter(Boolean).slice(0, 200),
      hiddenFrom: (Array.isArray(body.hiddenFrom) ? body.hiddenFrom : []).map((x) => str(x, 40)).filter(Boolean).slice(0, 200),
      createdAt: now(),
      likes: [],
      comments: []
    };
    appendMoment(moment);          // 只追加一行日志，不再整体重写 moments.json
    broadcastMoment(user.id, {
      type: 'moment', action: 'new', authorId: user.id, moment: visibleMoment(moment, user.id)
    });
    ok(res, { moment: visibleMoment(moment, user.id) });
    return;
  }

  if (parts[0] === 'moments' && method === 'POST' && parts[2] === 'like') {
    const m = db.moments.find((x) => x.id === parts[1]);
    if (!m) return fail(res, 404, '动态不存在');
    if (!momentAudience(m.authorId).includes(user.id)) return fail(res, 403, '看不到这条动态');
    if (!m.likes) m.likes = [];
    const idx = m.likes.findIndex((l) => l.userId === user.id);
    const liked = idx === -1;
    if (liked) m.likes.push({ userId: user.id, at: now() });
    else m.likes.splice(idx, 1);
    saveMoments();
    broadcastMoment(m.authorId, {
      type: 'moment', action: 'like', momentId: m.id, authorId: m.authorId, userId: user.id, liked
    });
    /* 朋友圈消息列表：别人赞了我的动态 → 记一条（取消赞就把那条撤掉） */
    if (liked) {
      pushMomentNotice(m.authorId, user.id, 'like', m.id, '');
    } else {
      for (let i = db.momentNotices.length - 1; i >= 0; i -= 1) {
        const r = db.momentNotices[i];
        if (r.momentId === m.id && r.fromUserId === user.id && r.kind === 'like') db.momentNotices.splice(i, 1);
      }
      saveMomentNotices();
    }
    ok(res, { moment: visibleMoment(m, user.id) });
    return;
  }

  /* 置顶 / 取消置顶自己发的动态：置顶的固定排在朋友圈最上面 */
  if (parts[0] === 'moments' && method === 'POST' && parts[2] === 'pin') {
    const m = db.moments.find((x) => x.id === parts[1]);
    if (!m) return fail(res, 404, '动态不存在');
    if (m.authorId !== user.id) return fail(res, 403, '只能置顶自己的动态');
    const body = await readBody(req);
    const on = body.pinned !== false;
    if (on) {
      /* 只能置顶一条：新的置顶把旧的取消（QQ空间/微博都是这个规矩） */
      db.moments.forEach((x) => { if (x.authorId === user.id && x.id !== m.id) delete x.pinned; });
    }
    if (on) m.pinned = true; else delete m.pinned;
    saveMoments();
    ok(res, { pinned: on });
    return;
  }

  /* 删评论：只能删自己发的；动态作者可以删自己动态下的任何评论（微信那套） */
  if (parts[0] === 'moments' && method === 'DELETE' && parts[2] === 'comments' && parts.length === 4) {
    const m = db.moments.find((x) => x.id === parts[1]);
    if (!m) return fail(res, 404, '动态不存在');
    const idx = (m.comments || []).findIndex((c) => c.id === parts[3]);
    if (idx < 0) return fail(res, 404, '这条评论不在了');
    const c = m.comments[idx];
    if (c.userId !== user.id && m.authorId !== user.id) return fail(res, 403, '只能删自己的评论');
    m.comments.splice(idx, 1);
    saveMoments();
    /* 评论删了，这条评论在「消息列表」里的那条通知也一起撤掉（微信也是删了就没） */
    for (let i = db.momentNotices.length - 1; i >= 0; i -= 1) {
      if (db.momentNotices[i].commentId === c.id) db.momentNotices.splice(i, 1);
    }
    saveMomentNotices();
    const audience = momentAudience(m.authorId);
    audience.forEach((id) => sendTo(id, {
      type: 'moment', action: 'comment-deleted', momentId: m.id, commentId: c.id
    }));
    ok(res, { deleted: true });
    return;
  }

  if (parts[0] === 'moments' && method === 'POST' && parts[2] === 'comments') {
    const m = db.moments.find((x) => x.id === parts[1]);
    if (!m) return fail(res, 404, '动态不存在');
    if (!momentAudience(m.authorId).includes(user.id)) return fail(res, 403, '看不到这条动态');
    /* 风控：被临时限制的账号先挡住 */
    const cmBlocked = riskBlocked(user);
    if (cmBlocked) return fail(res, 429, '账号功能被临时限制，还有 ' + cmBlocked + ' 分钟（如有疑问请联系管理员）');
    const body = await readBody(req);
    const content = str(body.content, 300);
    if (!content) return fail(res, 422, '评论不能为空');
    const replyTo = str(body.replyTo, 40) || null;
    if (!m.comments) m.comments = [];
    m.comments.push({ id: uid('cm'), userId: user.id, content, replyTo, at: now() });
    saveMoments();
    /* 朋友圈消息列表：评论了谁的动态就通知谁；回复某人的评论，被回复的人也收一条 */
    const newCommentId = m.comments[m.comments.length - 1].id;
    pushMomentNotice(m.authorId, user.id, 'comment', m.id, content, { commentId: newCommentId });
    if (replyTo && replyTo !== m.authorId) {
      pushMomentNotice(replyTo, user.id, 'reply', m.id, content, { commentId: newCommentId });
    }
    const views = visibleMoment(m, user.id);
    const audience = momentAudience(m.authorId);
    audience.forEach((id) => {
      sendTo(id, {
        type: 'moment',
        action: 'comment',
        momentId: m.id,
        authorId: m.authorId,
        comment: views.comments[views.comments.length - 1],
        commentCount: views.comments.length
      });
    });
    ok(res, { moment: views });
    return;
  }

  if (parts[0] === 'moments' && method === 'DELETE' && parts.length === 2) {
    const idx = db.moments.findIndex((x) => x.id === parts[1]);
    if (idx === -1) return fail(res, 404, '动态不存在');
    if (db.moments[idx].authorId !== user.id) return fail(res, 403, '只能删除自己发的动态');
    const [removed] = db.moments.splice(idx, 1);
    saveMoments();
    broadcastMoment(user.id, {
      type: 'moment', action: 'delete', momentId: removed.id, authorId: user.id
    });
    ok(res, { deleted: true });
    return;
  }

  /* 用户举报：App 里长按消息 / 动态可以举报，后台「举报处理」里看 */
  if (parts[0] === 'reports' && method === 'POST') {
    const body = await readBody(req);
    const target = findUser(str(body.targetUserId, 40));
    if (!target) return fail(res, 404, '被举报的人不存在');
    const row = {
      id: uid('rp'),
      at: now(),
      byUserId: user.id,
      byName: user.nickname || user.username,
      targetUserId: target.id,
      targetName: target.nickname || target.username,
      reason: str(body.reason, 60) || '未填写原因',
      content: str(body.content, 300),
      chatId: str(body.chatId, 60),
      status: 'open'
    };
    opsStore.reports.unshift(row);
    if (opsStore.reports.length > 500) opsStore.reports.length = 500;
    saveReports();
    audit(req, null, '用户举报', target.username, row.reason);
    ok(res, { reported: true });
    return;
  }

  /* 二进制直传：视频/图片直接把原始字节 PUT 上来，不再塞 base64
     （base64 会多传 33%，一条 5MB 视频要多跑 1.7MB 流量 → 手机上就是多等十几秒） */
  if (parts[0] === 'upload' && parts[1] === 'raw' && method === 'POST') {
    const clientSaidCompressed = String(req.headers['x-chris-compressed'] || '').trim() === '1';   // CHRIS_UPLOAD_SKIP_SHRINK_V1
    if (!uploadRateAllow(user.id)) {
      return fail(res, 429, '上传太频繁了，歇一会儿再传');
    }
    if (uploadDirFull()) return fail(res, 507, '服务器空间不够了，先清理上传目录');
    const ctype = String(req.headers['content-type'] || '').toLowerCase();
    let ext = 'bin';
    if (ctype.indexOf('video/') === 0) ext = ctype.indexOf('quicktime') >= 0 ? 'mov' : 'mp4';
    else if (ctype.indexOf('png') >= 0) ext = 'png';
    else if (ctype.indexOf('image/') === 0) ext = 'jpg';
    let name = uid('file') + '.' + ext;
    const outPath = path.join(UPLOAD_DIR, name);
    const MAX = 60 * 1024 * 1024;
    let size = 0, tooBig = false;
    const ws2 = fs.createWriteStream(outPath);
    await new Promise((resolve) => {
      req.on('data', (chunk) => {
        size += chunk.length;
        if (size > MAX) { tooBig = true; try { ws2.destroy(); } catch (err) { } req.destroy(); resolve(); }
      });
      req.on('end', () => resolve());
      req.on('error', () => resolve());
      req.pipe(ws2);
      ws2.on('close', () => resolve());
    });
    if (tooBig) { try { fs.unlinkSync(outPath); } catch (err) { } return fail(res, 413, '文件超过 60MB'); }
    if (!size) { try { fs.unlinkSync(outPath); } catch (err) { } return fail(res, 422, '没有收到文件'); }
    /* 这个口原来是"写进去就不管了"：图片炸弹能从这里溜进来。
       现在图片一律过一遍尺寸体检：超限直接拒，大图自动缩小。 */
    if (ctype.indexOf('image/') === 0) {
      try {
        const buf2 = fs.readFileSync(outPath);
        const mime2 = sniffImageMime(buf2) || (ctype.indexOf('png') >= 0 ? 'image/png' : 'image/jpeg');
        const img2 = checkImage(buf2, mime2);
        if (!img2.ok) { try { fs.unlinkSync(outPath); } catch (err) { } return fail(res, 422, img2.error); }
        let final2 = img2.buffer;
        if (img2.needShrink && !clientSaidCompressed) {      // CHRIS_UPLOAD_SKIP_SHRINK_V1
          const small2 = shrinkImageBuffer(img2.buffer, '.' + ext);
          if (small2 && small2.length) final2 = small2;
        }
        fs.writeFileSync(outPath, final2);
        size = final2.length;
      } catch (err) {
        try { fs.unlinkSync(outPath); } catch (err2) { }
        return fail(res, 422, '图片校验失败');
      }
    }
    /* 视频：按视频号同一套规格压一遍（720p / 1.2Mbps / faststart）再落盘。
       以前「传多大存多大」—— 聊天里一条 10MB 的视频，对方手机上要转十几秒才出画面。 */
    /* App 端已经自己压好的视频（带 x-chris-compressed: 1）就别再压一遍：
       服务端再压一遍 = 用户白等十几秒 + 画质再掉一层。2026-09-25 */
    const clientCompressed = String(req.headers['x-chris-compressed'] || '').trim() === '1';
    /* 客户端说自己压过了也不能全信：iPhone 直出的 .mov 仍有 3.4Mbps / 7.6MB 的，
       弱网下 AVPlayer 得把整个文件下完才出画面，用户看到的就是「点开一片黑 / 卡住」。
       所以再看一眼实际码率：超过 1.6Mbps 或文件超过 3MB，就按视频号那套重压一遍。 */
    const videoTooBig = ctype.indexOf('video/') === 0 && size > 2 * 1024 * 1024 &&
      (!clientCompressed || size > 3 * 1024 * 1024 || videoBitrateOf(outPath) > 1600000);
    if (videoTooBig) {
      const before = size;
      try {
        const tmpIn = path.join(os.tmpdir(), 'chris-up-' + crypto.randomBytes(6).toString('hex') + '.' + ext);
        const outTmp = tmpIn + '.small.mp4';
        fs.writeFileSync(tmpIn, fs.readFileSync(outPath));
        const rr = await runFfAsync(ffmpegExe(), ['-y', '-loglevel', 'error', '-i', tmpIn,
          '-vf', "scale='if(gt(iw,ih),min(1280,iw),-2)':'if(gt(iw,ih),-2,min(1280,ih))'",
          '-c:v', 'libx264', '-profile:v', 'high', '-preset', 'veryfast',
          '-b:v', '1200k', '-maxrate', '1500k', '-bufsize', '3000k',
          '-r', '30', '-g', '60', '-keyint_min', '60', '-sc_threshold', '0',
          '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '96k', '-ac', '1',
          '-movflags', '+faststart', outTmp], 300000);
        if (rr.ok && fs.existsSync(outTmp)) {
          const nb = fs.readFileSync(outTmp);
          const smallName = uid('file') + '.mp4';
          fs.writeFileSync(path.join(UPLOAD_DIR, smallName), sealUploadBuffer(smallName, nb));
          try { fs.unlinkSync(outPath); } catch (err) { }
          name = smallName;
          size = nb.length;
          callTrace('聊天视频压缩 ' + Math.round(before / 1024) + 'KB → ' + Math.round(size / 1024) + 'KB');
        }
        try { fs.unlinkSync(outTmp); } catch (err) { }
        try { fs.unlinkSync(tmpIn); } catch (err) { }
      } catch (err) {
        callTrace('聊天视频压缩失败，用原文件：' + String(err && err.message || err).slice(0, 120));
      }
    }
    /* 上传目录里的东西一律加密落盘（以前这个口是直接写明文，重启才补加密） */
    sealUploadInPlace(name);
    noteUpload(user.id, size);
    ok(res, { url: '/uploads/' + name, bytes: size });
    return;
  }

  if (parts[0] === 'upload' && method === 'POST') {
    if (!uploadRateAllow(user.id)) {
      return fail(res, 429, '上传太频繁了，歇一会儿再传（10 分钟最多 60 个、200MB）');
    }
    if (uploadDirFull()) {
      return fail(res, 507, '服务器空间不够了，先让管理员清一下上传目录');
    }
    const body = await readBody(req);
    const saved = saveUploadedFile(body);
    if (saved.error) return fail(res, saved.status, saved.error);
    noteUpload(user.id, saved.bytes || 0);
    ok(res, saved);
    return;
  }

  fail(res, 404, '接口不存在');
}

/* ------------------------------------------------------------------ 静态 */

let assetVersionCache = { at: 0, version: '' };

/** public 目录的指纹：任何前端文件改动都会让版本号变，用来提示/自动刷新页面 */
function assetVersion() {
  const t = Date.now();
  if (assetVersionCache.version && t - assetVersionCache.at < 1000) return assetVersionCache.version;
  const hash = crypto.createHash('sha1');
  try {
    fs.readdirSync(PUBLIC_DIR).sort().forEach((name) => {
      try {
        const st = fs.statSync(path.join(PUBLIC_DIR, name));
        if (st.isFile()) hash.update(name + ':' + st.size + ':' + Math.round(st.mtimeMs));
      } catch (err) { /* 单个文件读不到就跳过 */ }
    });
  } catch (err) { /* 目录读不到就用空指纹 */ }
  const version = hash.digest('hex').slice(0, 12);
  assetVersionCache = { at: t, version };
  return version;
}

/** 能压缩的文本类型（html/css/js/json/svg…） */
const COMPRESSIBLE = { '.html': 1, '.css': 1, '.js': 1, '.json': 1, '.svg': 1, '.txt': 1 };
/** 压缩结果按 文件+版本 缓存，避免每次请求都压一遍 */
const gzipCache = new Map();

function gzipFor(file, buf, version) {
  const key = file + '|' + version;
  const hit = gzipCache.get(key);
  if (hit) return hit;
  const gz = zlib.gzipSync(buf, { level: 6 });
  if (gzipCache.size > 40) gzipCache.clear();
  gzipCache.set(key, gz);
  return gz;
}

function sendFile(req, res, file, rel) {
  fs.stat(file, (err, stat) => {
    if (err || !stat.isFile()) return fail(res, 404, '文件不存在: ' + rel);
    const ext = path.extname(file).toLowerCase();
    const version = assetVersion();
    const acceptGzip = /\bgzip\b/.test(String(req.headers['accept-encoding'] || ''));
    /* 安全：上传目录里只允许"直接显示"的媒体类型；其它一律当二进制附件下载，
       并且禁掉浏览器猜类型 —— 不然传个 .html/.svg 上来就能当网页跑脚本（存储型 XSS）。 */
    const inUploads = String(rel || '').indexOf('/uploads/') === 0;
    /* 上传目录里的文件是**加密落盘**的（见 sealUploadBuffer）：
       对外服务时先解密到内存再发。热文件留一份缓存，避免每次请求都解一遍。 */
    let plain = null;
    /* 视频/音频边下边播、拖进度条会连着发很多 Range 请求：
       这种请求只解需要的那一段（见 readUploadRange），不再把整个文件解一遍。 */
    const rangeHdr = String(req.headers.range || '').trim();
    const wantRange = /^bytes=/.test(rangeHdr);
    const sealed = inUploads ? uploadIsSealed(file) : false;
    if (inUploads && !(wantRange && sealed)) {
      try { plain = readUploadPlain(file); } catch (e2) { plain = null; }
    }
    const totalSize = plain ? plain.length : (sealed ? Math.max(0, stat.size - 20) : stat.size);
    /* 访问流水带上 Range 和真实状态：以后「视频怎么一直在转圈」看这一行就知道
       客户端是在整包下载（200）还是分片边下边播（206）、要的是哪一段。 */
    if (inUploads) {
      const r0 = /^bytes=(\d*)-(\d*)$/.exec(rangeHdr);
      uploadAccessLog(clientInfo(req).ip, (r0 && (r0[1] || r0[2])) ? 206 : 200,
        path.basename(file), req.url,
        'range=' + (rangeHdr || '-') + ' size=' + totalSize + (sealed ? ' sealed' : ' plain')
          + ' ua=' + String(req.headers['user-agent'] || '').slice(0, 24).replace(/\s+/g, '_'));
    }
    /* 能"直接在播放器里放"的后缀。少了 .mov 会出大事：iPhone 拍的视频（朋友圈/聊天
       里发的都是 .mov）会被当成附件，回 application/octet-stream + attachment，
       AVPlayer 拿到这种响应根本放不出来 —— 用户反馈的"朋友圈视频播放不出来"
       就是这个（.mp4 的没事，所以以前看着是好的）。 */
    const DISPLAYABLE = ['.png', '.jpg', '.jpeg', '.webp', '.gif', '.ico',
      '.mp4', '.m4v', '.mov', '.webm', '.mp3', '.m4a', '.aac', '.ogg', '.wav'];
    const forceDownload = inUploads && DISPLAYABLE.indexOf(ext) < 0;
   const headers = {
      'Content-Type': forceDownload ? 'application/octet-stream' : (MIME[ext] || 'application/octet-stream'),
      'X-Content-Type-Options': 'nosniff',
      /* 上传目录里的东西（头像、封面、朋友圈图、聊天图、视频、语音）文件名都是随机生成的，
         永远不会被同名覆盖 —— 所以可以按「一年内不用再问服务器」来发。
         以前一律 no-cache，App 每次启动、每次翻列表都要重新校验一遍每张图/每个视频，
         4G 上就是一顿一顿的（这是"卡"的主要来源之一）。
         页面和脚本仍然走 no-cache + ETag，保证后台改了刷新就能看到最新。 */
      'Cache-Control': inUploads
        ? 'public, max-age=31536000, immutable'
        : 'no-cache, must-revalidate',
      'ETag': '"' + version + '-' + stat.size + '"',
      'X-Asset-Version': version
    };
    /* 按真实内容定类型：大到几 MB 的 PNG 截图会被压成 JPEG（文件名不变，
       消息里的地址不用改），这时如果还按扩展名发 image/png，浏览器可能会挑刺。
       这里用已经解出来的明文头判断一下，稳一点。 */
    if (inUploads && plain && !forceDownload && plain.length > 3) {
      const h0 = plain[0], h1 = plain[1], h2 = plain[2];
      if (h0 === 0xff && h1 === 0xd8 && h2 === 0xff) headers['Content-Type'] = 'image/jpeg';
      else if (h0 === 0x89 && h1 === 0x50 && h2 === 0x4e) headers['Content-Type'] = 'image/png';
      else if (h0 === 0x52 && h1 === 0x49 && h2 === 0x46) headers['Content-Type'] = 'image/webp';
      else if (h0 === 0x47 && h1 === 0x49 && h2 === 0x46) headers['Content-Type'] = 'image/gif';
    }
    if (forceDownload) headers['Content-Disposition'] = 'attachment';
    if (req.headers['if-none-match'] === headers['ETag']) {
      res.writeHead(304, { 'Cache-Control': headers['Cache-Control'], 'ETag': headers['ETag'] });
      res.end();
      return;
    }
    if (ext === '.html') {
      /* 防木马的关键响应头：
         CSP    —— 只让本站自己的脚本跑，别人注入的 <script> 一律执行不了
         DENY   —— 不让别人用 iframe 套住这个页面（防点击劫持）
         Permissions-Policy —— 关掉屏幕录制等危险能力 */
      const inlineOk = /^(index|admin|admin2|manage|ai)\.html$/i.test(path.basename(file));
      headers['Content-Security-Policy'] = [
        "default-src 'self'",
        "script-src 'self'" + (inlineOk ? " 'unsafe-inline'" : ''),
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: blob: http: https:",
        "media-src 'self' data: blob: http: https:",
        "font-src 'self' data:",
        "connect-src 'self' http: https: ws: wss:",
        "object-src 'none'",
        /* 登录页允许被后台「实时预览」用 iframe 嵌，其它页面一律禁止被嵌套 */
        "frame-ancestors " + (/^login\.html$/i.test(path.basename(file)) ? "'self'" : "'none'"),
        "base-uri 'none'",
        "form-action 'none'"
      ].join('; ');
      headers['X-Frame-Options'] = 'DENY';
      headers['Permissions-Policy'] = 'display-capture=(), geolocation=(self), camera=(self), microphone=(self)';
      // 给 html 里的 css / js 加上 ?v=版本号，双保险
      let html = fs.readFileSync(file, 'utf8');
      html = html.replace(/(href|src)="([^":?]+\.(?:css|js))"/g, (m, attr, url) => attr + '="' + url + '?v=' + version + '"');
      let buf = Buffer.from(html, 'utf8');
      if (acceptGzip) {
        buf = gzipFor(file, buf, version);
        headers['Content-Encoding'] = 'gzip';
        headers['Vary'] = 'Accept-Encoding';
      }
      headers['Content-Length'] = buf.length;
      res.writeHead(200, headers);
      res.end(buf);
      return;
    }
    if (acceptGzip && COMPRESSIBLE[ext] && stat.size > 1024) {
      const buf = gzipFor(file, fs.readFileSync(file), version);
      headers['Content-Encoding'] = 'gzip';
      headers['Vary'] = 'Accept-Encoding';
      headers['Content-Length'] = buf.length;
      res.writeHead(200, headers);
      res.end(buf);
      return;
    }
    /* 视频/音频支持 Range 分片：播放器才能边下边播、拖进度条。
       以前只回整包（200），所以每条视频都要等整个下完才出画面 —— 又慢又卡。 */
    headers['Accept-Ranges'] = 'bytes';
    const range = rangeHdr;
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (m && (m[1] || m[2])) {
      let start = m[1] ? parseInt(m[1], 10) : Math.max(0, totalSize - parseInt(m[2], 10));
      let end = m[1] && m[2] ? parseInt(m[2], 10) : totalSize - 1;
      if (isNaN(start) || isNaN(end) || start > end || start >= totalSize) {
        res.writeHead(416, { 'Content-Range': 'bytes */' + totalSize });
        res.end();
        return;
      }
      end = Math.min(end, totalSize - 1);
      headers['Content-Range'] = 'bytes ' + start + '-' + end + '/' + totalSize;
      headers['Content-Length'] = end - start + 1;
      res.writeHead(206, headers);
      if (plain) res.end(plain.subarray(start, end + 1));
      else if (sealed) {
        let part = null;
        try { part = readUploadRange(file, path.basename(file), start, end); } catch (err) { part = null; }
        if (part) res.end(part);
        else fs.createReadStream(file, { start: start, end: end }).pipe(res);
      } else fs.createReadStream(file, { start: start, end: end }).pipe(res);
      return;
    }
    headers['Content-Length'] = totalSize;
    res.writeHead(200, headers);
    if (plain) res.end(plain);
    else if (sealed) streamUploadPlain(file, res);
    else fs.createReadStream(file).pipe(res);
  });
}

/* 上传图片的访问流水：谁取的、给没给、带没带签名。
   「背景加载不出来」这种事，看这个文件就知道是没请求到、还是被 403 挡了。 */
function uploadAccessLog(ip, status, name, url, extra) {
  try {
    const signed = /[?&]s=/.test(String(url || '')) ? 'signed' : 'noSig';
    fs.appendFileSync(path.join(DATA_DIR, 'uploads-access.log'),
      '[' + new Date().toISOString() + '] ' + status + ' ' + signed + ' ' + ip + ' ' + name
        + (extra ? ' ' + extra : '') + '\n', 'utf8');
  } catch (err) { /* 日志写不了不影响服务 */ }
}

/* ============================================================
   视频分片（HLS）：先播放后加载
   data/hls/<id>/index.m3u8 + seg_00000.ts（和服务端其它上传一样加密落盘）。
   整包 MP4 就算是边下边播，也要「从某个位置一直下到结尾」；切成 3 秒一段之后，
   AVPlayer 拿到第一段就能出画面，剩下的按播放进度边看边下。
   没生成过分片的视频回 404，客户端会自动退回整包 MP4，不会播不出来。
   ============================================================ */
const HLS_DIR = path.join(DATA_DIR, 'hls');

/* 新视频进 feed 后自动补 HLS 分片（防退化的那一步）。
   合并成一个 4 秒的防抖：连发几条视频只跑一次；detached + unref 所以
   不占请求、也不会拦着服务退出。 */
let hlsBuildTimer = null;
/* 视频号：发布之后的「后台处理」——转码成 720p/1.2Mbps、抽封面、再补 HLS 分片。
   跑完把 feed.json 里这条的 video/cover 换成处理好的版本；失败就保留原片（至少能看）。 */
async function processFeedVideoPost(postId, srcName, needCover) {
  try {
    const srcPath = path.join(UPLOAD_DIR, srcName);
    if (!fs.existsSync(srcPath)) return;
    const tmpSrc = uploadTempPlain(srcName);
    let finalVideo = '/uploads/' + srcName;
    let cover = "";
    try {
      if (fs.statSync(tmpSrc).size > 2.2 * 1024 * 1024) {
        const outTmp = tmpSrc + ".small.mp4";
        const rr = await runFfAsync(ffmpegExe(), ["-y", "-loglevel", "error", "-i", tmpSrc,
          "-vf", "scale='if(gt(iw,ih),min(1280,iw),-2)':'if(gt(iw,ih),-2,min(1280,ih))'",
          "-c:v", "libx264", "-profile:v", "high", "-preset", "ultrafast",
          "-b:v", "1200k", "-maxrate", "1500k", "-bufsize", "3000k",
          "-r", "30", "-g", "60", "-keyint_min", "60", "-sc_threshold", "0",
          "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", "-ac", "1",
          "-movflags", "+faststart", outTmp], 600000);
        if (rr.ok && fs.existsSync(outTmp)) {
          finalVideo = "/uploads/" + saveUploadPlain(fs.readFileSync(outTmp), ".mp4");
          callTrace("视频号后台转码 " + srcName + " → " + finalVideo
            + " (" + Math.round(fs.statSync(outTmp).size / 1024) + "KB, 1.2Mbps)");
        } else {
          callTrace("视频号后台转码失败，先用原片：" + String(rr.err || "").slice(0, 120));
        }
        try { fs.unlinkSync(outTmp); } catch (e1) { }
      }
      if (needCover) {
        const cTmp = tmpSrc + ".cover.jpg";
        const cr = await runFfAsync(ffmpegExe(), ["-y", "-loglevel", "error", "-ss", "0.3", "-i", tmpSrc,
          "-frames:v", "1", "-vf", "scale=576:-2", "-q:v", "6", cTmp], 60000);
        if (cr.ok && fs.existsSync(cTmp)) cover = "/uploads/" + saveUploadPlain(fs.readFileSync(cTmp), ".jpg");
        try { fs.unlinkSync(cTmp); } catch (e2) { }
      }
    } finally {
      try { fs.unlinkSync(tmpSrc); } catch (e3) { }
    }
    const file = path.join(DATA_DIR, "feed.json");
    const f = readJson(file, { items: [], posts: [] });
    const post = (Array.isArray(f.posts) ? f.posts : []).find((x) => x.id === postId);
    if (post) {
      if (finalVideo) post.video = finalVideo;
      if (cover) post.cover = cover;
      writeJson(file, f);
    }
    scheduleHlsBuild();
  } catch (err) {
    callTrace("视频号后台处理异常：" + String((err && err.message) || err).slice(0, 120));
  }
}

function scheduleHlsBuild() {
  try {
    if (hlsBuildTimer) clearTimeout(hlsBuildTimer);
    hlsBuildTimer = setTimeout(() => {
      hlsBuildTimer = null;
      try {
        const child = spawn(process.execPath, ['hls-build.js'], {
          cwd: __dirname, detached: true, stdio: 'ignore'
        });
        child.on('error', () => { });
        child.unref();
        callTrace('视频号：新视频已排队做 HLS 分片（自动）');
      } catch (e) { callTrace('视频号：HLS 自动分片起不来 ' + String(e && e.message || e)); }
    }, 4000);
  } catch (e) { }
}

/** 找同一个视频「重建后」的分片目录（<id>-t<时间戳>），多个就取最新的；没有返回 '' */
function findRebuiltHlsDir(id) {
  try {
    const prefix = String(id) + '-t';
    const list = fs.readdirSync(HLS_DIR).filter((d) => d.indexOf(prefix) === 0);
    if (!list.length) return '';
    list.sort((a, b) => {
      const ta = fs.statSync(path.join(HLS_DIR, a)).mtimeMs;
      const tb = fs.statSync(path.join(HLS_DIR, b)).mtimeMs;
      return tb - ta;
    });
    return list[0];
  } catch (e) { return ''; }
}

function serveHls(req, res, rel) {
  /* ['hls', id, 文件名]（主播放列表）或 ['hls', id, v0, 文件名]（480p/720p 那两档） */
  const parts = String(rel).split('/').filter(Boolean);
  if (parts.length < 3 || parts.length > 4) return fail(res, 404, '文件不存在');
  const hlsIp = clientInfo(req).ip;
  const id = parts[1].replace(/[^A-Za-z0-9._-]/g, '');
  const sub = parts.length === 4 ? parts[2].replace(/[^A-Za-z0-9._-]/g, '') : '';
  const name = parts[parts.length - 1].replace(/[^A-Za-z0-9._-]/g, '');
  if (!id || !name) return fail(res, 404, '文件不存在');
  const rootDir = path.join(HLS_DIR, id);
  const dir = sub ? path.join(rootDir, sub) : rootDir;
  const file = path.join(dir, name);
  if (file.indexOf(rootDir) !== 0) return fail(res, 403, '禁止访问');
  /* 和 /uploads 一个口径：开了「上传要签名」就必须带签名或登录 */
  if (secCfg().signUploads && !currentUser(req)) {
    let q = null;
    try { q = new URL(req.url, 'http://x').searchParams; } catch (err) { q = null; }
    if (!(q && uploadSigOk(name, q.get('e'), q.get('s')))) {
      strikeIp(clientInfo(req).ip, '裸链访问 HLS');
      uploadAccessLog(hlsIp, 403, name, req.url, 'hls');
      return fail(res, 403, '这个文件需要登录或签名链接才能访问');
    }
  }
  /* 分片重建过（目录名换成 <id>-t<时间戳>）时，客户端手里可能还拿着老 URL。
     老目录已经删掉了，直接 404 的话客户端会退回整包 MP4（又变重）——
     所以这里 302 到重建后的同名视频目录，播放列表和分片都走新的。 */
  if (!fs.existsSync(file)) {
    const alt = findRebuiltHlsDir(id);
    if (alt) {
      uploadAccessLog(hlsIp, 302, name, req.url, 'hls');
      res.writeHead(302, {
        Location: '/hls/' + alt + '/' + (sub ? sub + '/' : '') + name,
        'Cache-Control': 'no-store'
      });
      return res.end();
    }
  }
  if (!fs.existsSync(file)) {
    uploadAccessLog(hlsIp, 404, name, req.url, 'hls');
    return fail(res, 404, '文件不存在');
  }
  const ext = path.extname(name).toLowerCase();
  const type = ext === '.m3u8' ? 'application/vnd.apple.mpegurl'
    : (ext === '.ts' ? 'video/mp2t'
      : (ext === '.m4s' ? 'video/iso.segment' : 'application/octet-stream'));
  fs.stat(file, (err, stat) => {
    if (err || !stat.isFile()) return fail(res, 404, '文件不存在');
    const sealed = uploadIsSealed(file);
    const total = sealed ? Math.max(0, stat.size - 20) : stat.size;
    const headers = {
      'Content-Type': type,
      /* 播放列表每次都要新的（重新生成过分片就要立刻生效），分片本身永远不变 */
      'Cache-Control': ext === '.m3u8' ? 'no-cache, must-revalidate' : 'public, max-age=31536000, immutable',
      'X-Content-Type-Options': 'nosniff',
      'Accept-Ranges': 'bytes'
    };
    const range = String(req.headers.range || '').trim();
    const m = /^bytes=(\d*)-(\d*)$/.exec(range);
    if (m && (m[1] || m[2])) {
      let start = m[1] ? parseInt(m[1], 10) : Math.max(0, total - parseInt(m[2], 10));
      let end = m[1] && m[2] ? parseInt(m[2], 10) : total - 1;
      if (isNaN(start) || isNaN(end) || start > end || start >= total) {
        res.writeHead(416, { 'Content-Range': 'bytes */' + total });
        res.end();
        return;
      }
      end = Math.min(end, total - 1);
      headers['Content-Range'] = 'bytes ' + start + '-' + end + '/' + total;
      headers['Content-Length'] = end - start + 1;
      uploadAccessLog(hlsIp, 206, name, req.url, 'hls range=' + range);
      res.writeHead(206, headers);
      if (sealed) {
        let part = null;
        try { part = readUploadRange(file, name, start, end); } catch (e2) { part = null; }
        if (part) return res.end(part);
      }
      return fs.createReadStream(file, { start: sealed ? start + 20 : start, end: sealed ? end + 20 : end }).pipe(res);
    }
    headers['Content-Length'] = total;
    uploadAccessLog(hlsIp, 200, name, req.url, 'hls size=' + total);
    res.writeHead(200, headers);
    if (sealed) return streamUploadPlain(file, res);
    fs.createReadStream(file).pipe(res);
  });
}

function serveStatic(req, res, pathname) {
  let rel = decodeURIComponent(pathname);
  /* 首页 = 新的登录/注册页（原来的桌面版仍在 /index.html?desktop=1） */
  if (rel === '/' || rel === '') rel = '/login.html';
  /* 有人把链接和中文标点一起复制走了（"…/Luchat.ipa）；"）：
     这种请求直接给真正的安装包，别回 404。 */
  /* 大小写、以及尾巴上粘着中文标点的情况，统一给真正的安装包（Linux 文件名区分大小写，
     以前 /luchat.ipa 也会 404）。 */
  if (/^\/luchat\.ipa/i.test(rel)) rel = '/Luchat.ipa';
  /* 安装包直链：公开开关在 data/download.json（用包时 open，其他时间 gated）。
     gated 时必须带签名 —— 签名从 /download 换（登录过，或带后台暗号 ?k=xxx），30 分钟有效。 */
  if (rel === '/Luchat.ipa') {
    if (!appDownloadOpen()) {
      let q = null;
      try { q = new URL(req.url, 'http://x').searchParams; } catch (err) { q = null; }
      if (!appDownloadSigOk(q)) {
        const body = '<!doctype html><meta charset="utf-8"><title>需要通过下载入口</title>'
          + '<meta name="viewport" content="width=device-width,initial-scale=1">'
          + '<div style="font:16px/1.7 -apple-system,sans-serif;padding:40px 24px;text-align:center">'
          + '<h3>这个直链已经关闭</h3>'
          + '<p style="color:#888">请从下载入口进入：<a href="/download">打开下载页</a><br>'
          + '（新用户需要管理员给的邀请链接）</p></div>';
        res.writeHead(403, { 'Content-Type': 'text/html; charset=utf-8',
                             'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
        res.end(body);
        return;
      }
    }
  }
  /* 下载入口：给一条 30 分钟有效的签名链接（登录过 / 带后台暗号 k=xxx 都算） */
  if (rel === '/download') {
    let q = null;
    try { q = new URL(req.url, 'http://x').searchParams; } catch (err) { q = null; }
    const byKey = q && adminKeyOk(String(q.get('k') || ''));
    if (!byKey && !currentUser(req)) {
      const body = '<!doctype html><meta charset="utf-8"><title>需要邀请链接</title>'
        + '<meta name="viewport" content="width=device-width,initial-scale=1">'
        + '<div style="font:16px/1.7 -apple-system,sans-serif;padding:40px 24px;text-align:center">'
        + '<h3>安装包需要邀请才能下载</h3>'
        + '<p style="color:#888">找你认识的用户要一条邀请链接，或者先<a href="/login.html">登录</a>再下载。</p></div>';
      res.writeHead(403, { 'Content-Type': 'text/html; charset=utf-8',
                           'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
      res.end(body);
      return;
    }
    res.writeHead(302, { Location: appDownloadUrl(req), 'Cache-Control': 'no-store' });
    res.end();
    return;
  }
  /* 视频分片（HLS）：先播放后加载 —— 播放器拿到第一段就能出画面，
     后面按播放进度边看边下，不用像整包 MP4 那样从头拖到尾 */
  if (rel.indexOf('/hls/') === 0) return serveHls(req, res, rel);
  if (rel.startsWith('/uploads/')) {
    /* 上传目录默认不对外裸奔：要么带服务器签发的签名，要么本人已登录 */
    if (secCfg().signUploads) {
      const name = path.basename(rel);
      let q = null;
      try { q = new URL(req.url, 'http://x').searchParams; } catch (err) { q = null; }
      const sigOk = q && uploadSigOk(name, q.get('e'), q.get('s'));
      if (!sigOk && !currentUser(req)) {
        strikeIp(clientInfo(req).ip, '裸链访问上传文件');
        uploadAccessLog(clientInfo(req).ip, 403, name, req.url);
        return fail(res, 403, '这个文件需要登录或签名链接才能访问');
      }
    }
    return sendFile(req, res, path.join(UPLOAD_DIR, path.basename(rel)), rel);
  }
  const target = path.join(PUBLIC_DIR, path.normalize(rel).replace(/^(\.\.[/\\])+/, ''));
  if (!target.startsWith(PUBLIC_DIR)) return fail(res, 403, '禁止访问');
  return sendFile(req, res, target, rel);
}

/* ------------------------------------------------------------------ 启动 */

loadStore();
loadSecurityState();   // 恢复「登录失败计数 / IP 封禁」（重启也不会被清掉）
/* 钱的开工前自检：总账上每个账号最后那笔余额，必须和 users.json 对得上；
   对不上就大声报警（接真钱之前必须先查清，绝不带着不一致继续跑） */
moneySelfCheck();
ensureAdminKey();      // 后台入口暗号（没有就自动生成一个，写在 data/security.json）
migrateAllUserSecrets(); // 密码只存 scrypt 哈希：老账号/机器人里残留的明文就地转掉（原密码不变）
migrateMessagesToEncrypted(); // 聊天内容落盘加密：磁盘上剩下的明文消息一次性改成 AES-256-GCM 密文
migrateUploadsToEncrypted();  // 图片/语音/视频/文件同样加密落盘（AES-256-CTR + "LUC1" 头）
scheduleReminderTick();// 管家的定时提醒
/* 机器人相关要等模块全部加载完再做：给用户开欢迎会话时会走违规词检查，
   而违规检查用的 opsStore 在文件更下面才定义。原来在启动时就调用，会报
   「Cannot access 'opsStore' before initialization」——日志刷屏、欢迎语也发不出去。 */
setTimeout(() => {
  try {
    ensureBots();        // 建「AI 助手 / 管家 / 星联世界」几个机器人账号，并和所有人加好友
    try { dropSysFriendships(); } catch (e) {}   // 「星言团队」不是好友，只占会话列表一条
    /* 一次性补齐：所有还没有机器人会话的用户（含之前注册的），都给他们开好欢迎会话 */
    db.users.filter((u) => !u.bot).forEach((u) => { try { attachBotsFor(u); } catch (e) { } try { ensureSysChat(u); } catch (e) { } });
    welcomeBots();       // 给主要账号开个「欢迎」会话，一打开就能看到机器人
  } catch (e) {
    console.log('[bots] 启动异常：' + e.message);
  }
}, 0);

async function handleHttpRequest(req, res) {
  res.__req = req;      // sendJson 里判断客户端要不要 gzip 用（别的地方不用管）
  const parsed = new URL(req.url, 'http://' + (req.headers.host || 'localhost'));
  try {
    /* 被封的 IP：接口和上传文件一律 403；静态页面还让过，
       这样正常用户只是看到「操作失败」，不会整个 App 白屏。
       （状态存在 security-state.json，重启也不清） */
    const reqIp = clientInfo(req).ip;
    const bannedSec = ipBanRemain(reqIp);
    /* 封禁只拦「写」：发消息 / 上传 / 改资料；读的一律放行。
       以前这里连 /api/session、/api/chats、图片都挡，于是一旦误封到一个出口 IP，
       同一个 Wi-Fi、同一个运营商出口下面所有人的 App 都变成「正在连接…什么页面都没有」。
       误封的代价只能落在「发不出去」，绝不能落在「打不开」。 */
    const isWriteReq = !(req.method === 'GET' || req.method === 'HEAD' || req.method === 'OPTIONS');
    const gated = isWriteReq;
    if (bannedSec && gated) {
      const body = JSON.stringify({ ok: false, error: '这个 IP 已被临时封禁，请 ' + Math.ceil(bannedSec / 60) + ' 分钟后再试', details: null });
      res.writeHead(403, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body), 'Retry-After': String(bannedSec) });
      res.end(body);
      return;
    }
    /* 自助放行：带上正确暗号 + allowme=1 访问一次，就把请求者自己的 IP 加进白名单。
       手机流量 IP 老是变，没有这个口子每次都得手工加。暗号不对就记一笔 strike 再按 404 处理。 */
    if (isAdminPath(parsed.pathname) && parsed.searchParams.get('allowme')) {
      const selfIp = clientInfo(req).ip;
      const k = String(parsed.searchParams.get('k') || '');
      if (adminKeyOk(k)) {
        const list = adminWhitelist();
        if (list.indexOf(selfIp) < 0) {
          saveAdminWhitelist(list.concat([selfIp]));
          console.log('[后台白名单] 自助放行 ' + selfIp);
        }
        res.writeHead(302, {
          Location: parsed.pathname + '?k=' + encodeURIComponent(k),
          'Cache-Control': 'no-store'
        });
        res.end();
        return;
      }
      strikeIp(selfIp, '自助放行暗号错 ' + parsed.pathname);
    }
    /* 后台入口（严格白名单）：不在名单里的一律 404 —— 和「随便乱输一个不存在的路径」
       长得一模一样，不给任何"这里有后台"的线索。名单在后台「访问白名单」页里改。 */
    if (isAdminPath(parsed.pathname) && !adminAllowed(peerIp(req))) {
      /* 留痕：谁、什么时间、想开什么页面被 404 了。后台白名单排障全靠它。 */
      try {
        console.log('[后台白名单] 拒绝 ' + peerIp(req) + ' → ' + parsed.pathname
          + '（不在名单里：' + adminWhitelist().join(', ') + '）');
      } catch (err) { }
      if (parsed.pathname.indexOf('/api/') === 0) {
        const body = JSON.stringify({ ok: false, error: '接口不存在', details: null });
        res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
        res.end(body);
      } else {
        const body = '<!doctype html><meta charset="utf-8"><title>404 Not Found</title>'
          + '<h1>404 Not Found</h1><p>请求的页面不存在。</p>';
        res.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
        res.end(body);
      }
      return;
    }
    /* 后台一律走加密通道：明文 http 打开后台，密码和暗号会被同网段的人抓走。
       本机（127.0.0.1）除外，方便本地脚本；其它来源自动跳到 https://<主机>:5443。 */
    /* TLS 前端（/opt/chris/tlsproxy.js）是从本机 127.0.0.1 回源的：
       它已经替客户端做过 TLS，并且带了 X-Forwarded-Proto=https。
       以前这里只看 socket.encrypted —— 会把握手已经在 https 上的请求
       误判成明文，于是 https://<host>:5443/manage.html 自己 302 到自己，
       后台在公网永远打不开（ERR_TOO_MANY_REDIRECTS）。
       直接连明文口 5180 的外部请求仍然照旧跳到 5443，安全性不变。 */
    const _rawPeerAdmin = String((req.socket && req.socket.remoteAddress) || '')
      .replace('::ffff:', '');
    const _viaTlsFront = /^(127\.0\.0\.1|::1)$/.test(_rawPeerAdmin)
      && String(req.headers['x-forwarded-proto'] || '').toLowerCase() === 'https';
    if (isAdminPath(parsed.pathname) && !req.socket.encrypted && !_viaTlsFront
        && !/^(127\.0\.0\.1|::1)$/.test(peerIp(req))) {
      const hostOnly = String(req.headers.host || '').split(':')[0] || '192.168.2.7';
      res.writeHead(302, {
        Location: 'https://' + hostOnly + ':5443' + parsed.pathname + (parsed.search || ''),
        'Cache-Control': 'no-store'
      });
      res.end();
      return;
    }
    /* 前台（App / 网页版）也统一走加密通道：
       http://…:5180 上的任何请求都 308 跳到 https://…:5443。
       308 会保留请求方法和请求体，所以 App 不用改代码也能无感切换过来；
       浏览器里打开的 http://192.168.2.7:5180/m.html 也会自动变成 https。
       本机（127.0.0.1）不跳，方便服务器上的脚本和工具。 */
    if (!req.socket.encrypted && !/^(127\.0\.0\.1|::1)$/.test(peerIp(req))) {
      const hostOnly = String(req.headers.host || '').split(':')[0] || '192.168.2.7';
      /* 只对「网页」做跳转（浏览器跟跳转没问题）；
         接口（/api）和上传文件不走跳转 —— App 里的登录态不会因为跨端口跳转丢掉，
         保证老版本 App 依然能正常用。App 的安全性靠"新版 App 内置 https 地址"来解决。 */
      const isPage = /^\/(index|m|install|admin|admin2|manage|ai|login)\.html$/i.test(parsed.pathname) || parsed.pathname === '/';
      /* 这一段是 nginx 回源的（TCP 对端是本机），而且它已经替客户端做过 TLS：
         X-Forwarded-Proto=https。这时客户端那一段本来就是加密的，
         千万别再跳 5443 —— 那个端口在一些线路上是被拦的，一跳就打不开
         （用户反馈的「首页/下载页打不开」就是这个）。 */
      const rawPeerX = String((req.socket && req.socket.remoteAddress) || '').replace('::ffff:', '');
      const viaNginxTls = /^(127\.0\.0\.1|::1)$/.test(rawPeerX)
        && String(req.headers['x-forwarded-proto'] || '').toLowerCase() === 'https';
      if (viaNginxTls) {
        /* 已经是加密通道了：正常往下走，什么都不用做 */
      } else if (!isPage) {
        /* 接口请求：以前为了兼容老版 App 原样放行 —— 等于把密码和令牌放在明文上过网，
           抓包就能用。现在只放行本机 / 局域网（服务器上的脚本、内网调试），
           公网来的明文接口一律让他改用 https（新版 App 本来就是 https/wss）。 */
        /* 反向代理（nginx 在本机）回源时走的是明文口，但它已经替客户端做过 TLS 了：
           只看 X-Forwarded-Proto 就会把「经过 nginx 的加密请求」误判成明文而拒绝。
           所以：本机来的连接 + XFP=https 视为「已经是加密的」。 */
        /* 注意这里要用**原始 socket 地址**判断"是不是本机代理"：
           peerIp() 在本机连接时会优先信 X-Forwarded-For，拿它判断会把真实客户端 IP 当成对端。 */
        const rawPeer = String((req.socket && req.socket.remoteAddress) || '').replace('::ffff:', '');
        const proxyHttps = /^(127\.0\.0\.1|::1)$/.test(rawPeer)
          && String(req.headers['x-forwarded-proto'] || '').toLowerCase() === 'https';
        if (!isLocalOrLan(peerIp(req)) && !proxyHttps) {
          if (parsed.pathname.indexOf('/api/login') === 0 && parsed.pathname.indexOf('phone') < 0) {
            securityNotePlainLogin(req);
          }
          return fail(res, 403, '请用加密通道访问：https://' + hostOnly + ':5443'
            + (parsed.pathname || '') + '（明文请求会被同网络的人抓到密码）');
        }
        if (parsed.pathname.indexOf('/api/login') === 0 && parsed.pathname.indexOf('phone') < 0) {
          securityNotePlainLogin(req);
        }
      } else {
      const headers = {
        Location: 'https://' + hostOnly + ':5443' + parsed.pathname + (parsed.search || ''),
        'Cache-Control': 'no-store'
      };
      /* 打包成 App 的网页版是从 file:// 发请求的，跨域跳转要在这一跳也带上 CORS 头 */
      const origin = req.headers.origin;
      if (origin && origin !== 'null') {
        try {
          const o = new URL(origin);
          if (/^(localhost|127\.0\.0\.1|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+)$/.test(o.hostname)) {
            headers['Access-Control-Allow-Origin'] = origin;
            headers['Access-Control-Allow-Credentials'] = 'true';
          }
        } catch (err) { /* 忽略 */ }
      } else if (origin === 'null') {
        headers['Access-Control-Allow-Origin'] = 'null';
      }
      res.writeHead(308, headers);
      res.end();
      return;
      }
    }
    /* 后台页面要带暗号才开：/manage.html?k=<暗号>（开过一次会记 30 天的 Cookie）。
       没带暗号的请求一律当「没这个页面」，扫描器扫过去只会看到 404。 */
    /* 一次性免密链接：/manage.html?k=…&m=<token> —— 用掉立刻作废，并把 m 从地址里去掉 */
    /* 带密码直接进：/manage.html?k=<暗号>&pw=<管理员密码>
       —— 页面自己拿 pw 去 /api/admin/quicklogin 换登录态（同源 fetch，Cookie 一定存得住），
          然后把 pw 从地址里去掉。这里只在密码不对时记一笔，不再做 302（302 设的 Cookie
          有些内置浏览器不保存，会变成「跳过去了但还是登录页」）。 */
    if (/^\/(manage|admin|admin2|ai)\.html$/i.test(parsed.pathname) && parsed.searchParams.get('pw')
        && !verifySecretRecord(adminAuth, String(parsed.searchParams.get('pw') || '').trim())) {
      strikeIp(reqIp, '后台免密参数不对');
    }
    if (/^\/(manage|admin|admin2|ai)\.html$/i.test(parsed.pathname) && parsed.searchParams.get('m')) {
      const magicAdmin = takeMagicToken(parsed.searchParams.get('m'));
      if (magicAdmin) {
        const hostOnly = String(req.headers.host || '').split(':')[0] || '192.168.2.7';
        const proto = req.socket.encrypted ? 'https' : 'http';
        const port = req.socket.encrypted ? ':5443' : ':5180';
        res.writeHead(302, {
          Location: proto + '://' + hostOnly + port + parsed.pathname + '?k=' + encodeURIComponent(String(secCfg().adminKey || '')),
          'Set-Cookie': OPS_COOKIE + '=' + encodeURIComponent(signOpsToken(magicAdmin, peerIp(req)))
            + '; Path=/; HttpOnly; SameSite=Lax; Max-Age=' + Math.floor(OPS_SESSION_TTL_MS / 1000),
          'Cache-Control': 'no-store'
        });
        audit(req, magicAdmin, '免密链接进入后台', magicAdmin.username, '一次性');
        res.end();
        return;
      }
      strikeIp(reqIp, '用过期的后台免密链接');
    }
    if (/^\/(manage|admin|admin2|ai|index)\.html$/i.test(parsed.pathname) && isAdminPath(parsed.pathname)) {
      if (!adminEntryOk(req, parsed.searchParams)) {
        /* 没暗号也不直接甩 404 —— 给一个「输入暗号」的小页面，
           这样你平时那个地址 http://192.168.2.7:5180/manage.html 还是能用，
           只是第一次要输一次暗号（输对了这台设备记 30 天）。 */
        const wrong = !!(parsed.searchParams.get('k') || '').length;
        if (wrong) strikeIp(reqIp, '后台暗号输错 ' + parsed.pathname);
        const html = '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
          + '<title>后台入口</title><style>'
          + 'body{font:15px/1.7 -apple-system,"Microsoft YaHei",sans-serif;background:#0f1216;color:#dfe7ef;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}'
          + '.box{background:#161c24;border:1px solid #24303c;border-radius:12px;padding:26px 24px;width:320px;text-align:center}'
          + 'h1{font-size:16px;margin:0 0 6px;color:#7fc4ff}p{color:#7b8b9c;font-size:12px;margin:0 0 16px}'
          + 'input{width:100%;box-sizing:border-box;padding:10px 12px;border-radius:8px;border:1px solid #2c3a48;background:#0d1319;color:#fff;font-size:15px;letter-spacing:1px}'
          + 'button{width:100%;margin-top:12px;padding:11px;border:0;border-radius:8px;background:#2f7fd8;color:#fff;font-size:15px;font-weight:600}'
          + '.err{color:#ff8080;font-size:12px;margin-top:10px}</style>'
          + '<div class="box"><h1>管理员后台</h1><p>请输入后台访问暗号（在 桌面\\飞信\\后台密码.txt 里）</p>'
          + '<form method="get" action="' + parsed.pathname + '">'
          + '<input name="k" placeholder="访问暗号" autocomplete="off" autofocus>'
          + '<button type="submit">进入后台</button></form>'
          + (wrong ? '<div class="err">暗号不对，再试一次</div>' : '')
          + '</div>';
        res.writeHead(200, {
          'Content-Type': 'text/html; charset=utf-8',
          'Content-Length': Buffer.byteLength(html),
          'Cache-Control': 'no-store',
          'X-Frame-Options': 'DENY',
          'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'"
        });
        res.end(html);
        return;
      }
      const key = String(secCfg().adminKey || '');
      if (key) res.setHeader('Set-Cookie', 'chris_admin_key=' + encodeURIComponent(key) + '; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000');
    }
    if (parsed.pathname.startsWith('/api')) {
      /* API 限流：按 IP 算，10 秒内最多 300 个 /api 请求（约 30/秒）。
         正常用（一个手机）远远到不了；爬数据/刷接口会被卡住。
         注意：/uploads/ 下面的图片不算，不然翻通讯录会被误伤。 */
      const ip = clientInfo(req).ip;
      if (!apiRateAllow(ip, parsed.pathname)) {
        return fail(res, 429, '请求太频繁，稍等一下再试');
      }
      /* 跨域支持：打包进 App 的版本界面来自 file:// ，发请求到这个服务器属于跨域 */
      const origin = req.headers.origin;
      /* 安全：只对「自己人」回显 Origin —— 同主机、局域网 IP、file:// / null。
         以前是把任意 Origin 都回显回去（evil.com 也回显），配合 Cookie 就是个隐患。 */
      const host = String(req.headers.host || '');
      let originAllowed = false;
      if (origin && origin !== 'null') {
        try {
          const o = new URL(origin);
          originAllowed = o.host === host ||
            /^(localhost|127\.0\.0\.1|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+)$/.test(o.hostname);
        } catch (err) { originAllowed = false; }
      }
      if (origin && originAllowed) {
        res.setHeader('Access-Control-Allow-Origin', origin);
        res.setHeader('Vary', 'Origin');
        res.setHeader('Access-Control-Allow-Credentials', 'true');
      } else {
        res.setHeader('Access-Control-Allow-Origin', '*');   // 不带 Cookie 的公开读（老客户端兼容）
      }
      res.setHeader('Access-Control-Allow-Headers', 'content-type, authorization');
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE, OPTIONS');
      res.setHeader('Access-Control-Max-Age', '600');
      if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }
      await handleApi(req, res, parsed.pathname, parsed.searchParams);
      return;
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') return fail(res, 405, '静态资源只支持 GET');
    serveStatic(req, res, parsed.pathname);
  } catch (err) {
    const status = err.status || 500;
    if (status >= 500) console.error('[error]', err);
    fail(res, status, err.message || '服务器内部错误');
  }
}

const server = http.createServer(handleHttpRequest);

/* ============================================================
   后台只允许局域网/本机访问：
   /manage.html、/admin.html、/ai.html 和所有 /api/ops、/api/admin 接口，
   局域网以外的请求一律 403。以后如果要用隧道从外网管后台，
   把 data/ui.json 里的 adminLanOnly 改成 0 即可（不推荐）。
   ============================================================ */
function peerIp(req) {
  const raw = String((req.socket && req.socket.remoteAddress) || '').replace('::ffff:', '');
  if (raw === '127.0.0.1' || raw === '::1') {
    // 走隧道/本机代理时，真实来源在转发头里（只有本机才信这个头，防止伪造绕过）
    const fwd = String(req.headers['cf-connecting-ip'] || '').trim() ||
      String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
    if (fwd) return fwd.replace('::ffff:', '');
  }
  return raw;
}
function isLanAddress(ip) {
  const s = String(ip || '');
  return s === '127.0.0.1' || s === '::1' || s === 'localhost' ||
    /^10\./.test(s) || /^192\.168\./.test(s) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(s) || /^169\.254\./.test(s);
}
function adminLanOnlyOn() {
  const ui = readJson(path.join(DATA_DIR, 'ui.json'), {});
  return ui.adminLanOnly === undefined ? true : !!Number(ui.adminLanOnly);
}
function isAdminPath(pathname) {
  return pathname === '/manage.html' || pathname === '/admin.html' || pathname === '/ai.html' ||
    pathname.indexOf('/api/ops') === 0 || pathname.indexOf('/api/admin') === 0;
}

/** 后台入口暗号：数据里只存密文（scrypt + 盐），不再存明文。
    老数据里如果还是明文 adminKey，第一次验对的时候会自动升级成密文。 */
function adminKeyOk(k) {
  const file = path.join(DATA_DIR, 'security.json');
  let raw = {};
  try { raw = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return true; }
  const provided = String(k == null ? '' : k);
  if (raw.adminKeyHash && raw.adminKeySalt) {
    return verifySecretRecord({ salt: String(raw.adminKeySalt), hash: String(raw.adminKeyHash) }, provided);
  }
  if (raw.adminKey) {
    const ok = provided === String(raw.adminKey);
    if (ok) {
      /* 明文 → 密文：写回文件，把 adminKey 那行删掉 */
      try {
        const rec = makeSecretRecord(String(raw.adminKey));
        delete raw.adminKey;
        raw.adminKeyHash = rec.hash;
        raw.adminKeySalt = rec.salt;
        raw.adminKeyUpdatedAt = now();
        fs.writeFileSync(file, JSON.stringify(raw, null, 2), 'utf8');
        console.log('[安全] 后台入口暗号已从明文升级为密文');
      } catch (e) { }
    }
    return ok;
  }
  return true;       // 从来没设过暗号：不拦（老部署兼容）
}

/* 长连接的每 IP 限制（连接数 + 新建速率） */
/* 压测时可以临时放宽（用环境变量），默认值和以前一样 */
const WS_MAX_PER_IP = Number(process.env.WS_MAX_PER_IP) || 60;
const WS_NEW_PER_SEC = Number(process.env.WS_NEW_PER_SEC) || 30;
const wsConns = new Map();          // ip -> 当前条数
const wsRate = new Map();           // ip -> { t, n }

function wsAllow(ip) {
  const now = Date.now();
  const r = wsRate.get(ip) || { t: now, n: 0 };
  if (now - r.t > 1000) { r.t = now; r.n = 0; }
  r.n += 1;
  wsRate.set(ip, r);
  if (r.n > WS_NEW_PER_SEC) return 'rate';
  const cur = wsConns.get(ip) || 0;
  if (cur >= WS_MAX_PER_IP) return 'count';
  wsConns.set(ip, cur + 1);
  return '';
}
function wsRelease(ip) {
  const cur = wsConns.get(ip) || 0;
  if (cur <= 1) wsConns.delete(ip); else wsConns.set(ip, cur - 1);
}

/* API 限流：每 IP 10 秒最多 300 个 /api 请求 */
const API_WINDOW_MS = 10 * 1000;
/* 10 秒内的接口预算。原来是 200 —— 多人共用一个网络（家庭/公司 Wi-Fi、运营商 NAT）
   会共享这一个额度，一起用就容易被限流，表现成"卡/一直转圈"。
   放宽到 600（约 60/秒）仍然能挡住爬数据，但正常人怎么用都够。 */
const API_MAX_PER_WINDOW = Number(process.env.API_MAX_PER_WINDOW) || 600;
const apiHits = new Map();          // ip -> { t, n }

function apiRateAllow(ip, path) {
  const now = Date.now();
  let r = apiHits.get(ip);
  if (!r || now - r.t > API_WINDOW_MS) { r = { t: now, n: 0 }; apiHits.set(ip, r); }
  r.n += 1;
  if (apiHits.size > 5000) apiHits.clear();       // 防止这个表本身涨爆
  // 后台接口是人点出来的，单独放宽（600/10 秒）
  const cap = String(path || '').indexOf('/api/ops') === 0 ? 600 : API_MAX_PER_WINDOW;
  return r.n <= cap;
}

/* 发消息限流：每个人 10 秒最多 120 条（约 12 条/秒）。
   正常聊天绝对够；脚本刷屏、拿客户端当短信轰炸机都会被拦住。 */
const MSG_WINDOW_MS = 10 * 1000;
const MSG_MAX_PER_WINDOW = 60;    // 10 秒 60 条（约 6 条/秒），正常聊天够，刷屏会被卡
const msgHits = new Map();          // userId -> { t, n }

function msgRateAllow(userId) {
  const now = Date.now();
  let r = msgHits.get(userId);
  if (!r || now - r.t > MSG_WINDOW_MS) { r = { t: now, n: 0 }; msgHits.set(userId, r); }
  r.n += 1;
  if (msgHits.size > 5000) msgHits.clear();
  return r.n <= MSG_MAX_PER_WINDOW;
}

/* 全局消息吞吐闸门：防"多个账号一起刷"把硬盘写爆 / 把 CPU 打死 */
let globalMsgWindow = { t: Date.now(), n: 0 };
const GLOBAL_MSG_PER_SEC = 3000;
function globalMsgAllow() {
  const now = Date.now();
  if (now - globalMsgWindow.t > 1000) globalMsgWindow = { t: now, n: 0 };
  globalMsgWindow.n += 1;
  return globalMsgWindow.n <= GLOBAL_MSG_PER_SEC;
}

/* 文本清洗：文字炸弹（几千个换行 / 几千个一样的字 / 大量组合符）会让手机排版卡死 */
function sanitizeText(input) {
  let s = String(input == null ? '' : input);
  s = s.replace(/[\u0000-\u0008\u000B-\u001F\u007F]/g, '');        // 去掉控制字符（保留 \n）
  s = s.replace(/\n{4,}/g, '\n\n\n');                              // 最多 3 个连续换行
  s = s.replace(/(.)\1{60,}/g, (m, c) => c.repeat(60));            // 同一个字符最多重复 60 次
  s = s.replace(/([\u0300-\u036F\u0483-\u0489]{10,})/g, '$1'.slice(0, 10)); // 组合符压到 10 个
  s = s.replace(/\S{500,}/g, (m) => m.slice(0, 500) + '…');        // 一个没有空格的长串最多 500 字（排版最怕这种）
  return s.slice(0, 4000);
}

/* 朋友圈限流：每人 1 分钟最多 20 条、1 天最多 300 条（防刷爆数据和 CPU） */
const momentHits = new Map();       // userId -> { t, n, day, dayN }
function momentRateAllow(userId) {
  const now = Date.now();
  const day = Math.floor(now / 86400000);
  let r = momentHits.get(userId);
  if (!r) r = { t: now, n: 0, day, dayN: 0 };
  if (now - r.t > 60000) { r.t = now; r.n = 0; }
  if (r.day !== day) { r.day = day; r.dayN = 0; }
  momentHits.set(userId, r);
  if (momentHits.size > 5000) momentHits.clear();
  return r.n < 20 && r.dayN < 300 ? (r.n += 1, r.dayN += 1, true) : false;
}

/* 搜索限流：每人 10 秒最多 30 次。
   防止有人写脚本按字母表逐条扫，把全站通讯录一次性扒下来。 */
const searchHits = new Map();       // userId -> { t, n }
function searchRateAllow(userId) {
  const now = Date.now();
  let r = searchHits.get(userId);
  if (!r) r = { t: now, n: 0 };
  if (now - r.t > 10000) { r.t = now; r.n = 0; }
  r.n += 1;
  searchHits.set(userId, r);
  if (searchHits.size > 5000) searchHits.clear();
  return r.n <= 30;
}

/* 手机号验证码限流：每个 IP 10 分钟最多 10 次（防号码库撞库） */
const phoneCodeHits = new Map();    // ip -> { t, n }
function phoneCodeRateAllow(ip) {
  const now = Date.now();
  let r = phoneCodeHits.get(ip);
  if (!r || now - r.t > 600000) { r = { t: now, n: 0 }; phoneCodeHits.set(ip, r); }
  r.n += 1;
  if (phoneCodeHits.size > 5000) phoneCodeHits.clear();
  return r.n <= 10;
}

/* 面对面建群限流：每人 10 分钟最多 10 次（4 位数字太短，不禁就成穷举入口） */
const faceCodeHits = new Map();     // userId -> { t, n }
function faceCodeRateAllow(userId) {
  const now = Date.now();
  let r = faceCodeHits.get(userId);
  if (!r || now - r.t > 600000) { r = { t: now, n: 0 }; faceCodeHits.set(userId, r); }
  r.n += 1;
  if (faceCodeHits.size > 5000) faceCodeHits.clear();
  return r.n <= 10;
}

/* 上传配额：防止有人（或坏掉的客户端）一直传把硬盘塞满。
   每人 10 分钟最多 60 个文件、最多 200MB；整个上传目录超过 8GB 就不再收。 */
const UPLOAD_WINDOW_MS = 10 * 60 * 1000;
const UPLOAD_MAX_COUNT = 60;
const UPLOAD_MAX_BYTES = 200 * 1024 * 1024;
const UPLOAD_DIR_MAX = 8 * 1024 * 1024 * 1024;
const uploadHits = new Map();       // userId -> { t, n, bytes }

function uploadRateAllow(userId) {
  const now = Date.now();
  let r = uploadHits.get(userId);
  if (!r || now - r.t > UPLOAD_WINDOW_MS) { r = { t: now, n: 0, bytes: 0 }; uploadHits.set(userId, r); }
  if (uploadHits.size > 5000) uploadHits.clear();
  return r.n < UPLOAD_MAX_COUNT && r.bytes < UPLOAD_MAX_BYTES;
}
function noteUpload(userId, bytes) {
  const r = uploadHits.get(userId);
  if (!r) return;
  r.n += 1;
  r.bytes += bytes;
}
function uploadDirFull() {
  try {
    const files = fs.readdirSync(UPLOAD_DIR);
    let total = 0;
    for (const f of files) {
      try { total += fs.statSync(path.join(UPLOAD_DIR, f)).size; } catch (err) { }
    }
    return total > UPLOAD_DIR_MAX;
  } catch (err) { return false; }
}

function handleWsUpgrade(req, socket) {
  const key = req.headers['sec-websocket-key'];
  if (!key || String(req.headers.upgrade || '').toLowerCase() !== 'websocket') {
    socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
    return;
  }
  /* 实时通道必须是加密的 wss：明文 ws:// 会把令牌和聊天内容摊在网络上。
     公网来的明文 ws 一律挡掉（本机 / 局域网还留着，方便内网调试）。 */
  /* 同上：nginx 在本机做的 TLS，回源是明文，但客户端那一侧是加密的 */
  const rawPeerWs = String((req.socket && req.socket.remoteAddress) || '').replace('::ffff:', '');
  const proxyHttpsWs = /^(127\.0\.0\.1|::1)$/.test(rawPeerWs)
    && String(req.headers['x-forwarded-proto'] || '').toLowerCase() === 'https';
  if (!req.socket.encrypted && !proxyHttpsWs && !isLocalOrLan(clientInfo(req).ip)) {
    securityNotePlainWs(clientInfo(req).ip);
    strikeIp(clientInfo(req).ip, '明文 ws 连实时通道');
    socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
    return;
  }
  /* 连接数/连接速率限制：防止一个 IP 开几千条连接（每条都发几十 MB 畸形帧）把服务拖死。
     正常用户一个设备就一条长连接，60 条上限完全够。 */
  const wsIp = clientInfo(req).ip;
  if (ipBanRemain(wsIp)) {
    socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
    return;
  }
  const why = wsAllow(wsIp);
  if (why) {
    socket.end('HTTP/1.1 429 Too Many Requests\r\n\r\n');
    return;
  }
  socket.on('close', () => wsRelease(wsIp));
  let user = currentUser(req);
  if (!user) {
    /* 打包进 App 的版本带不了 Cookie，WebSocket 允许用 ?token= 认证 */
    try {
      const q = new URL(req.url, 'http://localhost');
      const data = verifyTokenData(q.searchParams.get('token'));
      const u = data && db.users.find((x) => x.id === data.sub);
      /* 被顶下线的旧手机：连长连接也不给连（不然它还能白收消息） */
      const phoneOk = !u ? false : (((data.k || 'phone') !== 'phone')
        || (Number(data.ps) || 0) === (Number(u.phoneSession) || 0));
      if (u && (data.v || 0) === (u.tokenVersion || 0) && phoneOk) user = u;
    } catch (err) { /* 忽略 */ }
  }
  if (user && user.banned) {
    socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
    return;
  }
  if (!user) {
    /* 令牌过期时 App 会不停重连长连接：这种别记 strike（不然自己人把整个 IP 刷封），
       只有完全不带 token 参数的裸连接才算异常 */
    if (!/token=/.test(String(req.url || ''))) strikeIp(wsIp, '未授权连 WebSocket');
    socket.end('HTTP/1.1 401 Unauthorized\r\n\r\n');
    return;
  }
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
    'Upgrade: websocket\r\n' +
    'Connection: Upgrade\r\n' +
    'Sec-WebSocket-Accept: ' + ws.acceptKey(key) + '\r\n\r\n'
  );
  socket.setNoDelay(true);
  /* 客户端会带 X-App-Build（"B456 · 09-23 21:08" 这种）——
     记在 socket 上，通话日志里打出来，排查「两台手机版本不一样」时一眼可见 */
  socket.__appBuild = String(req.headers['x-app-build'] || '').slice(0, 40);
  socket.__deviceId = String(req.headers['x-device-id'] || '').slice(0, 64);
  /* 端类型（手机 / 平板 / 电脑）：顶下线时只踢手机，平板电脑留着 */
  socket.__kind = deviceKindOf(req);
  callTrace('ws 连上(带IP) ' + user.id + ' ip=' + wsIp + (socket.encrypted ? ' wss' : ' ws')
    + ' 版本=' + String(req.headers['x-app-build'] || '?'));
  userIps.set(user.id, wsIp);           // 记一下每个账号的出口 IP：通话时判断两边是不是同一个网络
  handleSocket(user, socket);
}

server.on('upgrade', handleWsUpgrade);

server.on('error', (err) => {
  console.error('');
  if (err.code === 'EADDRINUSE') {
    console.error('  ✗ 启动失败：端口 ' + PORT + ' 已被占用。');
    console.error('    换端口：set PORT=5181 && node server.js');
  } else {
    console.error('  ✗ 启动失败：' + err.message);
  }
  console.error('');
});

server.listen(PORT, BIND_HOST, () => {
  console.log('CHRIS Chat 已启动');
  /* 后台预热朋友圈图片尺寸（分批、不阻塞请求） */
  try { warmMomentSizes(); } catch (err) { /* 预热失败不影响使用 */ }
  /* 内置 TURN：语音/视频通话直连不上时，声音走服务器中转（手机 4G、
     路由器 AP 隔离、公司网挡 UDP 这些情况全靠它）。端口 3478/udp。 */
  try {
    require('./turn.js').startTurn({
      port: TURN_PORT_NUM, user: TURN_USER, pass: TURN_PASS, realm: TURN_REALM,
      log: (m) => { console.log('  ' + m); callTrace(m); }
    });
  } catch (err) {
    console.log('  ✗ TURN 没起来：' + err.message);
  }
  const replayed = replayMomentsLog();          // 把上次没合并的朋友圈日志并回 moments.json
  if (replayed) console.log('  朋友圈 合并追加日志 ' + replayed + ' 条');
  console.log('  前台   http://' + HOST + ':' + PORT + '/');
  console.log('  管理   http://' + HOST + ':' + PORT + '/admin.html');
  if (BIND_HOST === '0.0.0.0') {
    // 顺便列出局域网地址，方便手机访问
    try {
      const nets = os.networkInterfaces();
      Object.keys(nets).forEach((name) => {
        (nets[name] || []).forEach((n) => {
          if (n.family === 'IPv4' && !n.internal) {
            console.log('  手机   http://' + n.address + ':' + PORT + '/   （' + name + '，手机连同一个 Wi-Fi）');
          }
        });
      });
    } catch (err) { /* 忽略 */ }
  }
  console.log('  数据   ' + DATA_DIR);
  console.log('  用户 ' + db.users.length + ' 人 · 会话 ' + db.chats.length + ' 个');
  try { expireTransfers(); } catch (err) { /* 忽略 */ }
  try { expireRedPackets(); } catch (err) { /* 忽略 */ }
  setInterval(() => {
    try { expireTransfers(); } catch (err) { /* 忽略 */ }
    try { expireRedPackets(); } catch (err) { /* 忽略 */ }
  }, 60 * 1000);
  if (adminJustCreated) {
    console.log('');
    console.log('  ┌────────────────────────────────────────────┐');
    console.log('  │  管理后台密码已生成                        │');
    console.log('  │  密码：' + DEFAULT_ADMIN_PASSWORD.padEnd(34) + '│');
    console.log('  │  文件：data/admin.json（scrypt 哈希）      │');
    console.log('  └────────────────────────────────────────────┘');
  } else {
    console.log('  管理   需要密码登录（密码存于 data/admin.json）');
  }
});

process.on('SIGINT', () => { console.log('\n正在退出…'); server.close(() => process.exit(0)); });
process.on('SIGTERM', () => process.exit(0));

/* 兜底：任何一处没接住的异常都不能让整个服务退出（否则一条恶意请求就能把所有人踢下线）。
   记一条日志，继续服务。 */
process.on('uncaughtException', (err) => {
  console.error('[未捕获异常] ' + (err && err.stack ? err.stack : err));
});
process.on('unhandledRejection', (reason) => {
  console.error('[未处理的 Promise 拒绝] ' + (reason && reason.stack ? reason.stack : reason));
});

/* -------------------------------------------------------------- HTTPS
   手机端语音/视频通话要用麦克风、摄像头，而浏览器只允许「安全页面」调用它们，
   http://192.168.x.x 这种局域网地址不算安全页面，所以额外起一个 HTTPS 端口。
   证书放在 app/tls/server.pfx（自签，第一次访问手机浏览器会提示不安全，点「继续访问」即可）。 */
const HTTPS_PORT = Number(process.env.HTTPS_PORT || 5443);
function startHttps() {
  const tlsDir = path.join(__dirname, 'tls');
  const pfxPath = path.join(tlsDir, 'server.pfx');
  const passPath = path.join(tlsDir, 'pass.txt');
  if (!fs.existsSync(pfxPath)) return;
  let passphrase = '';
  try { if (fs.existsSync(passPath)) passphrase = fs.readFileSync(passPath, 'utf8').trim(); } catch (err) { /* 忽略 */ }
  const httpsServer = https.createServer(
    { pfx: fs.readFileSync(pfxPath), passphrase: passphrase || undefined },
    handleHttpRequest
  );
  httpsServer.on('upgrade', handleWsUpgrade);
  httpsServer.on('error', (err) => console.error('  ✗ HTTPS 没起来：' + err.message));
  httpsServer.listen(HTTPS_PORT, BIND_HOST, () => {
    console.log('  通话   https://' + HOST + ':' + HTTPS_PORT + '/m.html   （手机用这个地址才能打电话）');
    if (BIND_HOST === '0.0.0.0') {
      try {
        const nets = os.networkInterfaces();
        Object.keys(nets).forEach((name) => {
          (nets[name] || []).forEach((n) => {
            if (n.family === 'IPv4' && !n.internal) {
              console.log('  通话   https://' + n.address + ':' + HTTPS_PORT + '/m.html   （手机用这个地址才能打电话）');
            }
          });
        });
      } catch (err) { /* 忽略 */ }
    }
  });
}
startHttps();

/* ==================================================================
   独立的管理员后台：/manage.html
   —— 多账号 + 角色权限 + 全量审计日志 + 敏感词风控 + 消息检索
   —— 只走 /api/ops/* 自己的接口，不直接碰数据库文件
   ================================================================== */

const OPS_FILE = 'ops.json';
const SENSITIVE_FILE = 'sensitive.json';
const REPORTS_FILE = 'reports.json';
const VIOLATIONS_FILE = 'violations.json';
const APPROVALS_FILE = 'ops-approvals.json';   // 高危操作的复核工单（双人复核）
const AUDIT_FILE = 'audit.log';
const ICONS_FILE = 'icons.json';
const OPS_COOKIE = 'chris_ops';

/* 角色 = 一串权限点（最小权限原则）。
   每个角色只拿到「干这件事需要的那几项」，读和写也分开：

   超管     全部（含支付、后台账号、界面配置、封号、解除好友）
   审核员   看用户资料 + 封号；看/撤回消息；风控（敏感词·违规）；处理举报；朋友圈删违规动态
   客服     看用户资料 + 重置密码；看消息（排查用户问题）。不能封号、不能看钱、不能动内容
   运维     服务器指标；发公告；看审计日志。**看不到任何用户资料和聊天记录**（隐私）
   ------------------------------------------------------------------ */
const OPS_ROLES = {
  super: ['dashboard', 'users', 'users.ban', 'users.reset', 'users.money',
    'messages', 'messages.write', 'friends', 'friends.write',
    'risk', 'risk.write', 'reports', 'moments', 'moments.write',
    'payments', 'payments.write', 'ops', 'ops.write', 'system',
    'audit', 'admins', 'icons', 'icons.write', 'support', 'support.write'],
  /* 审核运营（规范）：只能看举报 / 朋友圈 / 用户基础信息；**不能封号**，也看不到审计日志。
     以前这里带着 users.ban —— 等于审核员能封号，和规范不符，已经去掉。 */
  auditor: ['dashboard', 'users', 'messages', 'messages.write',
    'risk', 'risk.write', 'reports', 'moments', 'moments.write', 'support'],
  /* 客服（规范）：只能查用户、会话投递日志；不能封号，也不能重置密码。 */
  support: ['dashboard', 'users', 'messages', 'support', 'support.write'],
  /* 运维（规范）：看服务器监控和日志，不允许操作用户账号。 */
  ops: ['dashboard', 'system', 'ops', 'ops.write', 'audit']
};
const OPS_ROLE_NAMES = { super: '超级管理员', auditor: '内容审核运营', support: '客服', ops: '运维' };

/* ---------------------------------------------------------------- IM 后台配置
   规范里那套「运营配置 / 系统设置」（风控阈值、App 版本、告警、角色权限）
   统一落在一个文件里，改完立即生效，不用重启服务。

   说明：这套后台的数据源仍然是 data/*.json（没有引 MySQL）。
   规范里列的 admin_user / im_group / message_delivery_log 这些「表」，
   在这里分别对应：ops.json（后台账号）、chats.json（会话/群）、
   messages/<chatId>.jsonl（消息）、reads.json（已读游标→投递状态）、
   friendships.json（好友/申请）、friendmeta.json（黑名单）、
   moments.json（朋友圈/评论）、risk.json + risk-events.jsonl（风控与处罚）。 */
const IMADMIN_FILE = path.join(DATA_DIR, 'imadmin.json');
let imAdminCache = null;
function imAdminCfg() {
  if (imAdminCache) return imAdminCache;
  const raw = readJson(IMADMIN_FILE, null);
  imAdminCache = (raw && typeof raw === 'object') ? raw : {};
  return imAdminCache;
}
function saveImAdmin(patch) {
  imAdminCache = Object.assign({}, imAdminCfg(), patch);
  try { writeJson(IMADMIN_FILE, imAdminCache); } catch (err) { }
  return imAdminCache;
}
/* 角色权限：默认用代码里的 OPS_ROLES，后台「角色权限配置」改过就用改过的 */
function rolePerms() {
  const custom = imAdminCfg().roles;
  if (custom && typeof custom === 'object') return custom;
  return OPS_ROLES;
}

/* 红点提醒：后台可以逐个位置设成 auto（按真实数据）/ on（一直亮）/ off（不显示） */
const BADGE_DEFAULT = {
  chats: 'auto',        // 底部第一个「微信」：未读数字
  contacts: 'auto',     // 底部「通讯录」：有人加好友
  discover: 'auto',     // 底部「发现」：有人发朋友圈
  me: 'off',            // 底部「我」
  newFriends: 'auto',   // 通讯录里「新的朋友」那一行
  momentsRow: 'auto'    // 发现页里「朋友圈」那一行
};
const BADGE_KEYS = Object.keys(BADGE_DEFAULT);
const BADGE_VALUES = ['auto', 'on', 'off'];

const DEFAULT_SENSITIVE = ['赌博', '代开发票', '办证', '加微信刷单', '杀猪盘', '毒品'];



const opsStore = { admins: [], sensitive: [], reports: [], violations: [], approvals: [], dualReview: false };

function loadOps() {
  const raw = readJson(path.join(DATA_DIR, OPS_FILE), { admins: null });
  let admins = Array.isArray(raw.admins) ? raw.admins : [];
  if (!admins.length) {
    const salt = crypto.randomBytes(16).toString('hex');
    admins = [{
      id: uid('ops'), username: 'admin', name: '超级管理员', role: 'super',
      salt, hash: hashPassword(DEFAULT_ADMIN_PASSWORD, salt), createdAt: now(), disabled: false
    }];
    writeJson(path.join(DATA_DIR, OPS_FILE), { admins });
  }
  opsStore.admins = admins;

  const sen = readJson(path.join(DATA_DIR, SENSITIVE_FILE), { words: null });
  if (Array.isArray(sen.words)) {
    opsStore.sensitive = sen.words;
  } else {
    opsStore.sensitive = DEFAULT_SENSITIVE.slice();
    writeJson(path.join(DATA_DIR, SENSITIVE_FILE), { words: opsStore.sensitive });
  }
  opsStore.reports = readJson(path.join(DATA_DIR, REPORTS_FILE), []);
  opsStore.violations = readJson(path.join(DATA_DIR, VIOLATIONS_FILE), []);
  /* 高危操作的双人复核：默认关（只有一个管理员时不能开，否则谁都批不了） */
  opsStore.dualReview = !!raw.dualReview;
  opsStore.approvals = readJson(path.join(DATA_DIR, APPROVALS_FILE), []);
  if (!Array.isArray(opsStore.approvals)) opsStore.approvals = [];
}
const saveOpsAdmins = () => writeJson(path.join(DATA_DIR, OPS_FILE), { admins: opsStore.admins, dualReview: !!opsStore.dualReview });
const saveApprovals = () => writeJson(path.join(DATA_DIR, APPROVALS_FILE), opsStore.approvals);
const saveSensitive = () => writeJson(path.join(DATA_DIR, SENSITIVE_FILE), { words: opsStore.sensitive });
const saveReports = () => writeJson(path.join(DATA_DIR, REPORTS_FILE), opsStore.reports);
const saveViolations = () => writeJson(path.join(DATA_DIR, VIOLATIONS_FILE), opsStore.violations);

/** 审计日志：只追加，不提供删除接口 */
function audit(req, admin, action, target, detail) {
  /* 日志也会被刷爆：超过 5MB 就归档一份，别把硬盘写满 */
  try {
    const p = path.join(DATA_DIR, AUDIT_FILE);
    if (fs.existsSync(p) && fs.statSync(p).size > 5 * 1024 * 1024) {
      try { fs.renameSync(p, p + '.1'); } catch (err) { try { fs.unlinkSync(p + '.1'); fs.renameSync(p, p + '.1'); } catch (e2) { } }
    }
  } catch (err) { }
  const ip = clientInfo(req).ip;
  const line = JSON.stringify({
    at: now(),
    admin: admin ? admin.username : '-',
    name: admin ? admin.name : '-',
    role: admin ? (OPS_ROLE_NAMES[admin.role] || admin.role) : '-',
    ip, action, target: target || '', detail: detail || ''
  });
  try { fs.appendFileSync(path.join(DATA_DIR, AUDIT_FILE), line + '\n'); } catch (err) { /* 忽略 */ }
}

function readAudit(limit) {
  try {
    const text = fs.readFileSync(path.join(DATA_DIR, AUDIT_FILE), 'utf8').trim();
    if (!text) return [];
    return text.split('\n').slice(-limit).reverse().map((l) => {
      try { return JSON.parse(l); } catch (err) { return null; }
    }).filter(Boolean);
  } catch (err) { return []; }
}

/* 审计日志按「年月日」核对：可传 from / to（毫秒时间戳）+ 关键词，
   返回命中的行、总条数，以及每天各自的条数（给后台做按天分组用） */
function readAuditQuery(opt) {
  const o = opt || {};
  const limit = Math.min(5000, Math.max(10, Number(o.limit) || 200));
  const from = Number(o.from) || 0;
  const to = Number(o.to) || 0;
  const q = String(o.q || '').trim().toLowerCase();
  const maxScan = 200000;
  /* 日志里的 at 存的是 ISO 字符串（"2026-09-18T08:11:59.996Z"），
     老代码直接 Number() 会变成 NaN→0，全被算成 1970 年 1 月 1 日，这里统一解析 */
  const tsOf = (v) => {
    if (typeof v === 'number' && isFinite(v)) return v;
    const n = Date.parse(String(v == null ? '' : v));
    return isNaN(n) ? 0 : n;
  };
  const pad = (n) => String(n).padStart(2, '0');
  const dayKey = (t) => {
    const d = new Date(tsOf(t));
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
  };
  let lines = [];
  try {
    const text = fs.readFileSync(path.join(DATA_DIR, AUDIT_FILE), 'utf8').trim();
    if (!text) return { rows: [], total: 0, days: [], truncated: false };
    lines = text.split('\n');
  } catch (err) {
    return { rows: [], total: 0, days: [], truncated: false };
  }
  const rows = [];
  const dayMap = new Map();
  let scanned = 0;
  let hit = 0;
  let truncated = false;
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    let a = null;
    try { a = JSON.parse(lines[i]); } catch (err) { continue; }
    if (!a) continue;
    scanned += 1;
    const at = tsOf(a.at);
    if (to && at > to) continue;                     // 比「结束日期」新 → 跳过
    if (from && at < from) break;                    // 日志是按时间追加的，更旧的不用再看
    if (q) {
      const hay = (String(a.name || '') + ' ' + String(a.admin || '') + ' ' + String(a.action || '') + ' '
        + String(a.target || '') + ' ' + String(a.detail || '') + ' ' + String(a.ip || '') + ' '
        + String(a.role || '')).toLowerCase();
      if (hay.indexOf(q) < 0) continue;
    }
    hit += 1;
    const k = dayKey(at);
    const dd = dayMap.get(k) || { day: k, count: 0, first: at, last: at };
    dd.count += 1;
    if (at < dd.first) dd.first = at;
    if (at > dd.last) dd.last = at;
    dayMap.set(k, dd);
    if (rows.length < limit) rows.push(a);
    else truncated = true;
    if (scanned >= maxScan) { truncated = true; break; }
  }
  const days = [...dayMap.values()].sort((x, y) => (x.day < y.day ? 1 : -1));
  return { rows, total: hit, days, truncated };
}

/* ---------------------------------------------------------- 敏感词 */

/* ==========================================================================
   风控引擎（腾讯式：多维打分 → 分级处置 → 证据留痕）
   信号：内容命中 / 外链 / 群发 / 频率 / 加好友过快 / 被举报 / 新设备 / 同 IP 多账号 / 历史处罚
   分级：正常 → 关注 → 受限（临时限功能）→ 高危（限功能 + 后台告警）
   注意：自动处置最多到"临时限制功能"，**封号永远要人工确认**。
   ========================================================================== */
const RISK_FILE = 'risk.json';
const RISK_EVENT_FILE = 'risk-events.jsonl';   // 只追加，作为处置证据
const RISK_DECAY_PER_HOUR = 4;                 // 每小时自然衰减 4 分（不白罚、也不轻易洗白）
let riskStoreCache = null;
let riskSaveTimer = null;

function loadRiskStore() {
  if (!riskStoreCache) riskStoreCache = readJson(path.join(DATA_DIR, RISK_FILE), { users: {} });
  if (!riskStoreCache.users) riskStoreCache.users = {};
  return riskStoreCache;
}
function saveRiskStore() {
  if (riskSaveTimer) return;
  riskSaveTimer = setTimeout(() => {
    riskSaveTimer = null;
    try { writeJson(path.join(DATA_DIR, RISK_FILE), loadRiskStore()); } catch (e) { }
  }, 3000);
}
function riskRecord(userId) {
  const s = loadRiskStore();
  const rec = s.users[userId] || (s.users[userId] = { score: 0, updatedAt: Date.now(), kinds: {}, restrictUntil: 0 });
  /* 时间衰减：离上次评估多久，就按小时往回退分 */
  const hours = Math.max(0, (Date.now() - (rec.updatedAt || Date.now())) / 3600000);
  if (hours > 0.05) rec.score = Math.max(0, Math.round((rec.score || 0) - hours * RISK_DECAY_PER_HOUR));
  rec.updatedAt = Date.now();
  return rec;
}
function riskLevelOf(score) {
  if (score >= 80) return { level: '高危', action: 'restrict24h' };
  if (score >= 60) return { level: '受限', action: 'restrict30m' };
  if (score >= 30) return { level: '关注', action: 'watch' };
  return { level: '正常', action: 'none' };
}
const RISK_DELTA = {
  sensitive: 25,      // 内容命中敏感词
  link: 10,           // 发外链
  mass_send: 30,      // 同一内容短时间发给很多人（群发/营销）
  fast_send: 15,      // 发送频率异常
  fast_friend: 20,    // 加好友过快（养号/营销）
  report: 20,         // 被举报
  login_new_device: 15, // 新设备/异地登录
  same_ip_multi: 15,  // 同一 IP 下大量不同账号
  signup_burst: 20,   // 同 IP 批量注册
};
/** 记一次风险事件，返回 {score, level, action} */
/* 风控白名单：这些用户名（老板的主号、测试号）**不参与自动风控** ——
   不记分、不限制、不进违规流。名单在 data/risk-whitelist.json：
     { "usernames": ["wzy245441545", "zimo19951010"] }
   （内容违规仍然会被人举报 → 人工处理，只是不再"自动把自己锁死"。） */
function riskWhitelisted(user) {
  if (!user || !user.username) return false;
  try {
    const raw = readJson(path.join(DATA_DIR, 'risk-whitelist.json'), { usernames: [] });
    const list = Array.isArray(raw.usernames) ? raw.usernames.map((s) => String(s).toLowerCase()) : [];
    return list.indexOf(String(user.username).toLowerCase()) >= 0;
  } catch (e) { return false; }
}
/* ---------------- 风控总开关 ----------------
   data/risk-config.json 里写 { "enabled": false } → 自动风控整套跳过：
   敏感词/外链记分、临时限制、媒体拦截、IP 自动封禁，全部不生效。
   只保留「有人举报 → 人工复核」（那是手动的，不会自动锁人）。 */
function riskOff() {
  try {
    const raw = readJson(path.join(DATA_DIR, 'risk-config.json'), { enabled: true });
    return !!(raw && raw.enabled === false);
  } catch (e) { return false; }
}
function riskEvent(user, kind, detail) {
  try {
    if (!user || !RISK_DELTA[kind]) return null;
    if (riskOff()) return null;
    /* 白名单（老板的主号 / 测试号）：不记分、不限制、不进违规流。
       名单在 data/risk-whitelist.json：{ "usernames": ["wzy245441545", ...] } */
    if (riskWhitelisted(user)) return null;
    const rec = riskRecord(user.id);
    const delta = RISK_DELTA[kind];
    /* 历史处罚也计入（违规记录 / 被封禁次数） */
    let hist = 0;
    try {
      const viol = (opsStore.violations || []).filter((v) => v.userId === user.id).length;
      hist = Math.min(20, viol * 3) + Math.min(20, (Number(user.banCount) || 0) * 10);
    } catch (e) { }
    rec.kinds[kind] = (Number(rec.kinds[kind]) || 0) + 1;
    rec.score = Math.max(0, Math.min(100, Math.round((rec.score || 0) + delta + Math.min(4, rec.kinds[kind] - 1) * 2 + (hist > rec.histApplied ? (hist - (rec.histApplied || 0)) : 0))));
    rec.histApplied = Math.max(rec.histApplied || 0, hist);
    const lv = riskLevelOf(rec.score);
    /* 分级处置：只在"受限/高危"时限功能，且是临时限制，不是封号 */
    if (lv.action === 'restrict30m') rec.restrictUntil = Math.max(rec.restrictUntil || 0, Date.now() + 30 * 60 * 1000);
    if (lv.action === 'restrict24h') rec.restrictUntil = Math.max(rec.restrictUntil || 0, Date.now() + 24 * 3600 * 1000);
    /* 证据留痕（只追加，不覆盖） */
    try {
      /* 事件流也会涨：超过 2MB 归档一份，免得把硬盘写满 */
      const evp = path.join(DATA_DIR, RISK_EVENT_FILE);
      if (fs.existsSync(evp) && fs.statSync(evp).size > 2 * 1024 * 1024) {
        try { fs.renameSync(evp, evp + '.1'); } catch (e2) {
          try { fs.unlinkSync(evp + '.1'); fs.renameSync(evp, evp + '.1'); } catch (e3) { }
        }
      }
      fs.appendFileSync(path.join(DATA_DIR, RISK_EVENT_FILE), JSON.stringify({
        at: now(), userId: user.id, username: user.username, kind, delta,
        score: rec.score, level: lv.level, restrictUntil: rec.restrictUntil || 0,
        ip: (detail && detail.ip) || '', device: (detail && detail.device) || '',
        note: (detail && detail.note) || ''
      }) + '\n', 'utf8');
    } catch (e) { }
    saveRiskStore();
    if (lv.action === 'restrict24h') console.log(`  [风控] ${user.username} 评分 ${rec.score}（高危）→ 临时限制 24 小时`);
    else if (lv.action === 'restrict30m') console.log(`  [风控] ${user.username} 评分 ${rec.score}（受限）→ 临时限制 30 分钟`);
    return { score: rec.score, level: lv.level, action: lv.action };
  } catch (e) { return null; }
}
/** 被临时限制的账号：挡在发消息/加好友/发动态之前 */
function riskBlocked(user) {
  if (!user) return 0;
  if (riskOff()) return 0;
  if (riskWhitelisted(user)) return 0;        // 白名单：永远不拦
  const rec = loadRiskStore().users[user.id];
  if (!rec || !rec.restrictUntil || rec.restrictUntil <= Date.now()) return 0;
  return Math.ceil((rec.restrictUntil - Date.now()) / 60000);   // 还剩多少分钟
}

/** 图片 / 视频 / 文件能不能发（黄赌毒那类内容没法"看图识别"，所以规矩定在账号上）：
    ① 有**未处理**的违规记录（命中过违禁词）→ 媒体一律先停，
       后台「敏感词·违规」里点一下「已处理」就恢复；
    ② 风控分到「高危」（80）以上 → 同样停媒体。
       （阈值用 80 而不是 30：像"同 IP 多账号"这种正常测试行为会打到 60~70 分，
        不能把测试账号的图片/视频也停了。）
    文字那条线照旧：命中违禁词当场拦截。 */
function mediaBlockedReason(user) {
  if (!user) return '';
  if (riskOff()) return '';
  if (riskWhitelisted(user)) return '';      // 白名单账号：图片/视频/文件也不拦
  const open = (opsStore.violations || []).filter((v) => v && v.userId === user.id && !v.handled);
  if (open.length) {
    return '这个账号有未处理的违规内容（' + open.length + ' 条），暂时不能发送图片 / 视频 / 文件；'
      + '请在「我的 → 设置 → 反馈」里说明情况，管理员处理后可恢复';
  }
  const rec = loadRiskStore().users[user.id];
  if (rec && (rec.score || 0) >= 80) {
    return '账号风控分偏高，暂时不能发送图片 / 视频 / 文件（如有疑问请联系管理员）';
  }
  return '';
}

/* 群发检测：同一内容在 10 分钟内发给了几个不同会话 */
const recentTextSends = new Map();   // userId -> [{hash, chatId, at}]
function noteTextSend(userId, chatId, text) {
  const list = (recentTextSends.get(userId) || []).filter((x) => Date.now() - x.at < 10 * 60 * 1000);
  const hash = crypto.createHash('sha1').update(String(text || '')).digest('hex').slice(0, 12);
  list.push({ hash, chatId, at: Date.now() });
  recentTextSends.set(userId, list.slice(-60));
  const same = list.filter((x) => x.hash === hash);
  const chats = new Set(same.map((x) => x.chatId));
  return chats.size;   // 同一内容发给了几个会话
}
/** 同一 IP 近一小时出现过几个不同账号（登录/注册） */
function ipAccountCount(ip) {
  try {
    return new Set((db.security.logins || [])
      .filter((l) => l.ip === ip && Date.now() - new Date(l.time).getTime() < 3600000)
      .map((l) => l.userId)).size;
  } catch (e) { return 0; }
}
/** 这个设备是不是该用户第一次用（粗粒度：IP+设备指纹） */
function isNewDevice(user, req) {
  try {
    const info = clientInfo(req);
    const seen = (db.security.logins || []).filter((l) => l.userId === user.id);
    if (!seen.length) return false;
    return !seen.some((l) => l.ip === info.ip || l.device === info.device);
  } catch (e) { return false; }
}

/* 每个账号自己记「登过的设备」（最多 10 条，最近的排前面）。
   滑动验证的「新设备」判断靠这张表 —— 全局的 security.logins 只有 600 条，
   用户一多就被别人的记录挤掉了，拿它判断等于永远不弹。 */
function rememberDevice(user, req) {
  try {
    if (!user) return;
    const info = clientInfo(req);
    const key = deviceKeyOf(info);
    const list = (Array.isArray(user.devices) ? user.devices : [])
      .filter((d) => deviceKeyOf(d) !== key);
    list.unshift({ id: info.deviceId || '', ip: info.ip, device: info.device,
                   model: friendlyModelName(info.model) || '', deviceMachine: info.model || '',
                   os: info.os || '', name: info.name || '', at: now() });
    if (list.length > 10) list.length = 10;
    user.devices = list;
    user.deviceUpdatedAt = now();
  } catch (e) { }
}

/** 一条设备记录 / 一次请求的「设备身份」：有设备 id 就用 id，没有才退回 IP+UA */
function deviceKeyOf(d) {
  if (d && d.deviceId) return 'id:' + String(d.deviceId);
  if (d && d.id) return 'id:' + String(d.id);
  return String((d && d.ip) || '') + '|' + String((d && d.device) || '');
}

/** 这台设备 / 这个出口 IP 在这个账号的设备表里见过吗 */
function knownDevice(user, req) {
  try {
    const info = clientInfo(req);
    const list = Array.isArray(user.devices) ? user.devices : [];
    if (!list.length) return true;            // 老账号还没这张表：不弹（别吓着老用户）
    if (info.deviceId) {
      /* 带设备 id 的表：认 id。表里全是老记录（还没有 id）时才退回 IP/UA 判断 */
      if (list.every((d) => !d.id)) {
        return list.some((d) => d.ip === info.ip || d.device === info.device);
      }
      return list.some((d) => d.id === info.deviceId);
    }
    return list.some((d) => d.ip === info.ip || d.device === info.device);
  } catch (e) { return true; }
}

/* 登录要不要弹滑动验证。跟微信一个思路：**默认不弹**，正常登录一路过；
   只有出现风险信号才要求补一次验证：
     ① 这台设备 / 这个出口 IP 从没登录过这个账号（新设备、异地登录）
     ② 最近 10 分钟内这个账号（≥3 次）或这个 IP（≥5 次）密码错得多
   想整层关掉：data/security.json 里写 "sliderLogin": 0。 */
function loginNeedsSlider(req, user) {
  try {
    if (!user) return false;
    const info = clientInfo(req);
    const t = Date.now();
    const byUser = LOGIN_FAILS.get('u:' + String(user.username || '').toLowerCase());
    if (byUser && t - byUser.first <= LOGIN_WINDOW_MS && byUser.n >= 3) return true;
    const byIp = LOGIN_FAILS.get('ip:' + info.ip);
    if (byIp && t - byIp.first <= LOGIN_WINDOW_MS && byIp.n >= 5) return true;
    /* 这台设备 / 这个 IP 从没见过 → 弹一次。
       设备表为空（老账号第一次用新版）等于「还不知道」，这时候不弹，
       免得所有老用户一升级就被要求验证。 */
    if (!knownDevice(user, req)) return true;
  } catch (e) { /* 风控出问题不能挡住正常登录 */ }
  return false;
}

/* 违规告警：以前只调不定义（命中敏感词会直接报错），这里补上 ——
   一份进后台「敏感词·违规」列表，一份进风控打分（sensitive +25）。 */
function recordViolation(user, chat, body, word) {
  try {
    const row = {
      id: uid('vio'),
      at: now(),
      userId: user ? user.id : '',
      username: user ? user.username : '',
      nickname: user ? (user.nickname || user.username) : '',
      chatId: chat ? chat.id : '',
      kind: chat ? 'chat' : 'content',
      word: String(word || ''),
      content: String(body || '').slice(0, 200),
      handled: false
    };
    opsStore.violations.unshift(row);
    if (opsStore.violations.length > 500) opsStore.violations.length = 500;
    saveViolations();
    if (user) riskEvent(user, 'sensitive', { note: '命中敏感词「' + word + '」' });
    return row;
  } catch (e) { return null; }
}

/* ---------------- 其余风控信号：登录 / 注册 / 加好友 ---------------- */
/** 登录风险评估。必须在 recordSecurity 之前调用：否则「这台设备以前登过没有」永远算不准 */
function noteLoginRisk(user, req) {
  try {
    if (!user || user.bot) return;                 // 机器人不参与风控，免得把评分榜刷满
    const info = clientInfo(req);
    if (isNewDevice(user, req)) riskEvent(user, 'login_new_device', { ip: info.ip, device: info.device, note: '新设备 / 异地登录' });
    const n = ipAccountCount(info.ip);
    if (n >= 8) riskEvent(user, 'same_ip_multi', { ip: info.ip, device: info.device, note: '同 IP 一小时内出现 ' + n + ' 个账号' });
  } catch (e) { }
}
/** 同一个 IP 24 小时内注册过几个账号 */
function signupSameIpCount(ip) {
  try {
    const cut = Date.now() - 24 * 3600 * 1000;
    return (db.security.logins || []).filter((l) => l.kind === 'register' && l.ip === ip
      && new Date(l.time).getTime() > cut).length;
  } catch (e) { return 0; }
}
/** 注册风险：同 IP 批量注册（机房换 IP 前最常见的薅号手法）。同样要放在 recordSecurity 之前 */
function noteSignupRisk(user, req) {
  try {
    const info = clientInfo(req);
    const n = signupSameIpCount(info.ip) + 1;      // 算上当前这一个
    if (n >= 3) riskEvent(user, 'signup_burst', { ip: info.ip, device: info.device, note: '同 IP 24 小时内注册 ' + n + ' 个账号' });
  } catch (e) { }
}
/** 加好友过快：10 分钟内发起的申请次数（营销号一天加几百个人的典型特征） */
const recentFriendReqs = new Map();
function noteFriendReqRisk(user) {
  const list = (recentFriendReqs.get(user.id) || []).filter((t) => Date.now() - t < 10 * 60 * 1000);
  list.push(Date.now());
  recentFriendReqs.set(user.id, list.slice(-200));
  if (list.length >= 10) riskEvent(user, 'fast_friend', { note: '10 分钟内发起 ' + list.length + ' 次好友申请' });
  return list.length;
}

/* ---------------- 后台风控面板要用的数据 ---------------- */
/** 评分榜：只看有分或有临时限制的账号，按分数倒序 */
function riskBoard(limit) {
  const s = loadRiskStore();
  return Object.keys(s.users).map((id) => {
    const rec = riskRecord(id);                    // 顺手做一次时间衰减
    const u = findUser(id);
    const lv = riskLevelOf(rec.score);
    return {
      userId: id,
      username: u ? u.username : '(已注销)',
      nickname: u ? (u.nickname || u.username) : '',
      score: Math.round(rec.score || 0),
      level: lv.level,
      banned: !!(u && u.banned),
      restrictMinutes: rec.restrictUntil && rec.restrictUntil > Date.now()
        ? Math.ceil((rec.restrictUntil - Date.now()) / 60000) : 0,
      kinds: rec.kinds || {},
      updatedAt: rec.updatedAt || 0
    };
  }).filter((r) => r.score > 0 || r.restrictMinutes > 0)
    .sort((a, b) => b.score - a.score || b.updatedAt - a.updatedAt)
    .slice(0, limit || 50);
}
/** 最近的风险事件（证据流，倒序） */
function riskEventsTail(limit) {
  try {
    const p = path.join(DATA_DIR, RISK_EVENT_FILE);
    if (!fs.existsSync(p)) return [];
    const text = fs.readFileSync(p, 'utf8').trim();
    if (!text) return [];
    return text.split('\n').slice(-(limit || 100)).reverse().map((l) => {
      try { return JSON.parse(l); } catch (e) { return null; }
    }).filter(Boolean);
  } catch (e) { return []; }
}

function sensitiveHit(text) {
  const s = String(text || '');
  if (!s) return '';
  for (let i = 0; i < opsStore.sensitive.length; i += 1) {
    const w = opsStore.sensitive[i];
    if (w && s.indexOf(w) >= 0) return w;
  }
  /* 链接：域名/路径里带黄赌毒、电诈特征的一律当敏感内容拦下来
     （中文靠上面那份词库，英文域名靠 badLinkHit） */
  const badLink = badLinkHit(s);
  if (badLink) return badLink;
  return '';
}

/* ---------------------------------------------------------- 后台登录态 */

function signOpsToken(admin, ip) {
  const payload = Buffer.from(JSON.stringify({
    sub: 'ops_' + admin.id, role: admin.role, exp: Date.now() + OPS_SESSION_TTL_MS,
    ip: ipFingerprint(ip)          // 令牌绑定登录时的 IP
  })).toString('base64url');
  const sig = crypto.createHmac('sha256', adminAuth.secret).update(payload).digest('base64url');
  return payload + '.' + sig;
}

function currentOps(req) {
  const auth = String((req.headers && req.headers.authorization) || '');
  let token = /^bearer\s+/i.test(auth) ? auth.replace(/^bearer\s+/i, '').trim() : '';
  if (!token) token = parseCookies(req)[OPS_COOKIE] || '';
  if (!token) return null;
  const parts = token.split('.');
  if (parts.length !== 2) return null;
  const expect = crypto.createHmac('sha256', adminAuth.secret).update(parts[0]).digest('base64url');
  const a = Buffer.from(parts[1]);
  const b = Buffer.from(expect);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  let data = null;
  try { data = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8')); } catch (err) { return null; }
  if (!data || typeof data.exp !== 'number' || data.exp <= Date.now()) return null;
  if (!data.sub || String(data.sub).indexOf('ops_') !== 0) return null;
  /* 令牌绑了 IP：换了 IP 就等于失效（防被人拷走 Cookie 在他机器上用） */
  if (data.ip && data.ip !== ipFingerprint(clientInfo(req).ip)) return null;
  const admin = opsStore.admins.find((x) => x.id === String(data.sub).slice(4));
  if (!admin || admin.disabled) return null;
  return admin;
}

function opsMe(admin) {
  return {
    id: admin.id, username: admin.username, name: admin.name, role: admin.role,
    roleName: OPS_ROLE_NAMES[admin.role] || admin.role,
    perms: rolePerms()[admin.role] || []
  };
}

function can(admin, perm) {
  const perms = OPS_ROLES[admin.role] || [];
  return perms.indexOf(perm) >= 0;
}

/* ==========================================================================
   高危操作的闸门：二次确认（+ 可选双人复核）
   ① 二次确认：不管点得多顺手，都要再输一次「当前登录管理员自己的密码」。
   ② 双人复核：后台默认关闭；一旦开启，下面这几类不可逆操作要另一个管理员
      用他自己的密码批准后才真正执行（腾讯的 4-eyes 那一层）。
   ③ 所有拦截、提交、批准、驳回都写审计日志（audit.log），不给删除接口。
   ========================================================================== */
const DANGEROUS_OPS = [
  { re: /^POST \/api\/ops\/users\/[^/]+\/ban$/, label: '封禁 / 解封账号' },
  { re: /^POST \/api\/ops\/users\/[^/]+\/reset$/, label: '重置用户密码' },
  { re: /^POST \/api\/ops\/messages\/[^/]+\/recall$/, label: '强制撤回消息' },
  { re: /^POST \/api\/ops\/chats\/[^/]+\/clear$/, label: '清空会话记录' },
  { re: /^POST \/api\/ops\/groups\/[^/]+\/dismiss$/, label: '解散群聊' },
  { re: /^POST \/api\/ops\/friendships\/[^/]+\/remove$/, label: '解除好友关系' },
  { re: /^DELETE \/api\/ops\/moments\/[^/]+$/, label: '删除朋友圈动态' },
  { re: /^DELETE \/api\/ops\/feed\/posts\/[^/]+$/, label: '删除视频号作品' },
  { re: /^POST \/api\/ops\/payments\/[^/]+\/revoke$/, label: '撤销交易' },
  { re: /^POST \/api\/ops\/payments\/freeze$/, label: '冻结 / 解冻账号（支付风控）' },
  { re: /^POST \/api\/ops\/wallet\/op$/, label: '处理提现申请' },
  { re: /^POST \/api\/ops\/system\/announce$/, label: '发布系统公告' },
  { re: /^POST \/api\/ops\/admins$/, label: '新增后台账号' },
  { re: /^POST \/api\/ops\/admins\/[^/]+\/disable$/, label: '停用 / 启用后台账号' },
  { re: /^POST \/api\/ops\/magic$/, label: '生成免密登录链接' },
  /* 敏感词库不算高危：它可逆、且日常维护脚本（管控违法内容.js）要反复调用，不设卡 */
];
/* 开了双人复核以后，这些「做完就回不了头」的操作必须别人点头 */
const DUAL_REVIEW_LABELS = [
  '封禁 / 解封账号', '撤销交易', '处理提现申请', '解散群聊', '清空会话记录',
  '删除朋友圈动态', '删除视频号作品', '解除好友关系', '新增后台账号', '停用 / 启用后台账号'
];
function dangerousOpOf(method, pathStr) {
  const key = method + ' ' + pathStr;
  for (let i = 0; i < DANGEROUS_OPS.length; i += 1) {
    if (DANGEROUS_OPS[i].re.test(key)) return DANGEROUS_OPS[i];
  }
  return null;
}
/** 二次确认：必须是「当前这个管理员自己的密码」，不是别人的、也不是链接里的暗号 */
function opsConfirmOk(admin, body) {
  const pw = String((body && body.confirmPassword) || '').trim();
  if (!pw) return false;
  try { return verifySecretRecord({ salt: admin.salt, hash: admin.hash }, pw); } catch (e) { return false; }
}
function canSeeApprovals(admin) {
  return admin.role === 'super' || can(admin, 'risk') || can(admin, 'ops') || can(admin, 'admins');
}
/* 复核工单的「原始参数」只放在内存里：重置密码这种操作，明文密码不进磁盘。
   落盘的只有脱敏版本（给后台列表看）。服务器重启后旧单子要重新提交，这是故意的。 */
const pendingOpBodies = new Map();
function sanitizeApprovalBody(body) {
  const out = {};
  Object.keys(body || {}).forEach((k) => {
    out[k] = /password|secret|token|passwd/i.test(k) ? '******' : body[k];
  });
  return out;
}
/* 复核工单只留最近 7 天 / 最多 200 条，别把 json 撑大 */
function pruneApprovals() {
  const cut = Date.now() - 7 * 86400000;
  opsStore.approvals = opsStore.approvals
    .filter((x) => x && ((x.status === 'pending') || (new Date(x.at).getTime() > cut)))
    .slice(0, 200);
  if (pendingOpBodies.size > 400) {
    const keep = {};
    opsStore.approvals.forEach((x) => { keep[x.id] = 1; });
    Array.from(pendingOpBodies.keys()).forEach((id) => { if (!keep[id]) pendingOpBodies.delete(id); });
  }
}

/* ---------------------------------------------------------- 统计 */

const msgTimes = [];               // 最近一分钟的消息时间戳（算 QPS）
let totalMessages = 0;
const STATS_FILE = 'stats.json';
const dailyStats = readJson(path.join(DATA_DIR, STATS_FILE), { day: '', messages: 0 });

function dayKey(ts) {
  const d = ts ? new Date(ts) : new Date();
  const p = (n) => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}
function localDayStart() {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}
function saveDailyStats() { writeJson(path.join(DATA_DIR, STATS_FILE), dailyStats); }

/* ============================================================
   成长体系（照 QQ 等级那套做）
   · 升级看「活跃天」：升到 L 级需要 L²+4L 个活跃天
     （Lv1=5 天、Lv4=32、Lv16=320、Lv32=1152、Lv64=4352 —— 和 QQ 的表一致）
   · 活跃天按当天使用时长记：满 2 小时 = 1 天，满 30 分钟 = 0.5 天，不足不计，
     每天最多 1 天（阈值/上限/加速倍数都能在后台改）
   · 等级图标：4 星 = 1 月亮、4 月亮 = 1 太阳、4 太阳 = 1 皇冠
     也就是 1 月亮 = 4 级、1 太阳 = 16 级、1 皇冠 = 64 级
   服务器在 UTC，所以「当天」一律按北京时间算（+8 小时，无夏令时）。
   ============================================================ */
const GROWTH_FILE = 'growth.json';
const ACTIVITY_FILE = 'activity.json';
const BJ_OFFSET_MS = 8 * 3600 * 1000;

const DEFAULT_GROWTH = {
  enabled: true,
  fullSeconds: 7200,        // 满 2 小时 = 1 个活跃天（QQ 的规则）
  halfSeconds: 1800,        // 满 30 分钟 = 0.5 个活跃天
  maxPerDay: 1,             // 每天最多涨 1 个活跃天
  boost: 1,                 // 加速倍数（后台可调；以后接会员就靠它）
  showInContacts: true,     // 通讯录昵称后显示等级图标
  showInChats: true,        // 聊天里/会话列表显示等级图标（QQ 就是到处都挂）
  showInProfile: true,      // 资料卡显示
  avatarFrame: true,        // 头像框（月亮银圈 / 太阳金环 / 皇冠金框）
  minShowLevel: 1,          // 从几级开始显示图标（填 16 = 只有太阳以上才显示）
  tip: '每天使用满 2 小时记 1 个活跃天，满 30 分钟记 0.5 个，不足 30 分钟不计。'
};

let growthCfgCache = null;
function readGrowthCfg() {
  if (!growthCfgCache) {
    const raw = readJson(path.join(DATA_DIR, GROWTH_FILE), {}) || {};
    growthCfgCache = Object.assign({}, DEFAULT_GROWTH, raw);
  }
  return growthCfgCache;
}
function saveGrowthCfg(patch) {
  const next = Object.assign({}, readGrowthCfg(), patch || {});
  growthCfgCache = next;
  writeJson(path.join(DATA_DIR, GROWTH_FILE), next);
  return next;
}
/** 后台改完要让在线客户端立刻拿到新配置 */
function publicGrowthCfg() {
  const c = readGrowthCfg();
  return {
    enabled: c.enabled !== false,
    fullSeconds: Math.max(60, Number(c.fullSeconds) || 7200),
    halfSeconds: Math.max(30, Number(c.halfSeconds) || 1800),
    maxPerDay: Math.max(0.5, Math.min(10, Number(c.maxPerDay) || 1)),
    boost: Math.max(1, Math.min(5, Number(c.boost) || 1)),
    showInContacts: c.showInContacts !== false,
    showInChats: c.showInChats === true,
    showInProfile: c.showInProfile !== false,
    avatarFrame: c.avatarFrame !== false,
    minShowLevel: Math.max(1, Math.min(144, Math.round(Number(c.minShowLevel) || 1))),
    tip: String(c.tip || DEFAULT_GROWTH.tip)
  };
}

/** 活跃天记账：{ 用户id: { day, seconds, earned, total, updatedAt } } */
let activityCache = null;
let activityDirty = false;
let activityTimer = null;
function activityMap() {
  if (!activityCache) {
    const raw = readJson(path.join(DATA_DIR, ACTIVITY_FILE), { users: {} }) || {};
    activityCache = (raw.users && typeof raw.users === 'object') ? raw.users : {};
  }
  return activityCache;
}
function saveActivitySoon() {
  activityDirty = true;
  if (activityTimer) return;
  activityTimer = setTimeout(() => {
    activityTimer = null;
    if (!activityDirty) return;
    activityDirty = false;
    try { writeJson(path.join(DATA_DIR, ACTIVITY_FILE), { users: activityMap() }); } catch (e) { }
  }, 2000);
  if (activityTimer.unref) activityTimer.unref();
}
/** 立刻落盘（后台手动改活跃天那种一次性操作，不等那 2 秒的攒批） */
function saveActivityNow() {
  activityDirty = false;
  try { writeJson(path.join(DATA_DIR, ACTIVITY_FILE), { users: activityMap() }); } catch (e) { }
}
function bjDayKey(ts) {
  return new Date((ts || Date.now()) + BJ_OFFSET_MS).toISOString().slice(0, 10);
}
/** 升到 L 级要多少个活跃天（QQ 的公式） */
function qqDaysForLevel(L) { return L * L + 4 * L; }
/** 有多少活跃天 = 几级（反解 L²+4L ≤ D，取整） */
function qqLevelOf(days) {
  const d = Math.max(0, Number(days) || 0);
  return Math.max(0, Math.floor(Math.sqrt(d + 4) - 2));
}
/** 等级拆成图标：皇冠/太阳/月亮/星星 */
function qqIconsOf(level) {
  let n = Math.max(0, Math.floor(Number(level) || 0));
  const crowns = Math.floor(n / 64); n = n % 64;
  const suns = Math.floor(n / 16); n = n % 16;
  const moons = Math.floor(n / 4); n = n % 4;
  return { crowns, suns, moons, stars: n };
}
function activityOf(uid) {
  const m = activityMap();
  if (!m[uid]) m[uid] = { day: '', seconds: 0, earned: 0, total: 0, updatedAt: '' };
  return m[uid];
}
/** 这个人现在几级（别人看他名字旁边那个图标用）
    和 QQ 一样：新号也是 1 级（1 颗星），所以最少返回 1；机器人不挂等级返回 0。 */
function qqLevelFor(uid) {
  if (!uid || !readGrowthCfg().enabled) return 0;
  const u = findUser(uid);
  if (u && u.bot) return 0;
  const m = activityMap();
  const a = m[uid];
  const lv = Math.max(1, qqLevelOf(a ? a.total : 0));
  /* 后台可以要求「到几级才显示」：不够就不返回，客户端自然不挂图标 */
  if (lv < publicGrowthCfg().minShowLevel) return 0;
  return lv;
}
function growthSnapshot(uid) {
  const cfg = publicGrowthCfg();
  const a = activityOf(uid);
  const today = bjDayKey();
  const todaySeconds = a.day === today ? Number(a.seconds) || 0 : 0;
  const todayEarned = a.day === today ? Number(a.earned) || 0 : 0;
  const level = qqLevelOf(a.total);
  /* 显示的等级和进度都按「最少 1 级」算：新号 1 颗星，攒够 12 天升 2 级 */
  const shown = Math.max(1, level);
  const nextDays = qqDaysForLevel(shown + 1);
  return {
    enabled: cfg.enabled,
    total: Math.round((Number(a.total) || 0) * 10) / 10,
    level,
    /* 显示用的等级：和 QQ 一样，新号也是 1 级（1 颗星） */
    levelShown: shown,
    icons: qqIconsOf(shown),
    levelStartDays: qqDaysForLevel(shown),
    nextDays,
    needDays: Math.max(0, Math.round((nextDays - (Number(a.total) || 0)) * 10) / 10),
    todaySeconds,
    todayEarned,
    cfg
  };
}
/** 上报一段使用时长（秒）→ 结算今天的活跃天 */
function pingActivity(uid, seconds) {
  const cfg = publicGrowthCfg();
  if (!cfg.enabled) return growthSnapshot(uid);
  const a = activityOf(uid);
  const today = bjDayKey();
  if (a.day !== today) { a.day = today; a.seconds = 0; a.earned = 0; }
  /* 单次最多认 1 小时，防止有人伪造一个巨大数字直接刷满 */
  const add = Math.max(0, Math.min(3600, Math.floor(Number(seconds) || 0)));
  a.seconds = (Number(a.seconds) || 0) + add;
  const raw = a.seconds >= cfg.fullSeconds ? 1 : (a.seconds >= cfg.halfSeconds ? 0.5 : 0);
  /* 会员升级加速：活跃天再乘会员倍数（会员 1.5 倍 / 超级会员 2 倍） */
  const want = Math.min(cfg.maxPerDay, raw) * cfg.boost * memberBoost(uid);
  if (want > (Number(a.earned) || 0)) {
    a.total = Math.round(((Number(a.total) || 0) + (want - (Number(a.earned) || 0))) * 10) / 10;
    a.earned = want;
    saveActivitySoon();
  }
  a.updatedAt = now();
  if (add > 0) saveActivitySoon();
  return growthSnapshot(uid);
}
/** 活跃榜（按总活跃天） */
function qqRanking(limit) {
  const m = activityMap();
  const rows = Object.keys(m)
    .map((id) => ({ id, total: Number(m[id].total) || 0 }))
    .filter((r) => r.total > 0)
    .sort((a, b) => b.total - a.total)
    .slice(0, Math.max(1, Math.min(200, Number(limit) || 50)))
    .map((r) => {
      const u = findUser(r.id) || {};
      return {
        id: r.id,
        name: u.nickname || u.username || '用户',
        avatar: u.avatar || '',
        total: Math.round(r.total * 10) / 10,
        level: qqLevelOf(r.total),
        icons: qqIconsOf(qqLevelOf(r.total))
      };
    });
  return rows;
}

/* ============================================================
   会员系统（我们自己的一套，逻辑照 QQ 会员那套）

   数据：data/membership.json
     cfg   —— 档位（会员 / 超级会员）、价格（月 / 季 / 年）、权益文案
     users —— 谁的会员、到期时间、开过几次（历史）
     codes —— 兑换码（后台生成，一张只能用一次）

   权益（服务端真正管用的那几条）：
     ① 升级加速：活跃天按倍数累计（会员 1.5 倍 / 超级会员 2 倍）
     ② 昵称挂会员徽章：会话列表 / 聊天 / 名片都带 memberTier
     ③ 名字用会员配色（客户端按 memberColor 上色）
     ④ 群人数上限放宽
   到期判断是「读的时候看 expireAt」，过期就当普通用户 —— 不用定时任务。
   ============================================================ */

const MEMBER_FILE = 'membership.json';
let memberCache = null;

const MEMBER_TIERS_DEFAULT = [
  { id: 'vip', name: '会员', short: 'VIP', color: '#E0B44A', color2: '#B8862A',
    boost: 1.5, groupMax: 500, price: { month: 10, quarter: 28, year: 98 } },
  { id: 'svip', name: '超级会员', short: 'SVIP', color: '#FF9A4D', color2: '#E2542A',
    boost: 2, groupMax: 1000, price: { month: 20, quarter: 56, year: 198 } }
];

const MEMBER_BENEFITS_DEFAULT = [
  { icon: 'bolt.fill', title: '升级加速', desc: '每天的活跃天按倍数累计，升级比别人快' },
  { icon: 'crown.fill', title: '会员标识', desc: '昵称后面挂专属徽章，名字用会员配色' },
  { icon: 'circle.dashed', title: '专属头像框', desc: '会员专属金环头像框' },
  { icon: 'person.3.fill', title: '群人数更多', desc: '能建更大的群（人数上限放宽）' },
  { icon: 'face.smiling.fill', title: '专属表情', desc: '会员专属表情包，免费领' }
];

function readMemberDb() {
  if (memberCache) return memberCache;
  const raw = readJson(path.join(DATA_DIR, MEMBER_FILE), null) || {};
  memberCache = {
    cfg: (raw.cfg && typeof raw.cfg === 'object') ? raw.cfg : {},
    users: (raw.users && typeof raw.users === 'object') ? raw.users : {},
    codes: Array.isArray(raw.codes) ? raw.codes : []
  };
  return memberCache;
}

function saveMemberDb() {
  try { writeJson(path.join(DATA_DIR, MEMBER_FILE), readMemberDb()); } catch (e) { }
}

function normalizeMemberTier(t, i) {
  const src = (t && typeof t === 'object') ? t : {};
  const price = (src.price && typeof src.price === 'object') ? src.price : {};
  const num = (v, def) => {
    const n = Number(v);
    return Number.isFinite(n) && n >= 0 ? Math.round(n * 100) / 100 : def;
  };
  return {
    id: String(src.id || '').slice(0, 20) || ('tier' + (i + 1)),
    name: String(src.name || '').trim().slice(0, 12) || ('会员' + (i + 1)),
    short: String(src.short || '').trim().slice(0, 8) || 'VIP',
    color: String(src.color || '#E0B44A').slice(0, 20),
    color2: String(src.color2 || '#B8862A').slice(0, 20),
    boost: Math.max(1, Math.min(10, Number(src.boost) || 1.5)),
    groupMax: Math.max(10, Math.min(20000, Math.floor(Number(src.groupMax) || 500))),
    price: { month: num(price.month, 10), quarter: num(price.quarter, 28), year: num(price.year, 98) }
  };
}

function memberCfg() {
  const raw = readMemberDb().cfg || {};
  const tiers = Array.isArray(raw.tiers) && raw.tiers.length ? raw.tiers : MEMBER_TIERS_DEFAULT;
  return {
    enabled: raw.enabled !== false,
    /* 后台能改的那几句文案 */
    title: String(raw.title || '会员中心').slice(0, 20),
    sub: String(raw.sub || '开通会员，升级更快、标识更亮').slice(0, 60),
    tiers: tiers.slice(0, 6).map(normalizeMemberTier),
    benefits: (Array.isArray(raw.benefits) && raw.benefits.length ? raw.benefits : MEMBER_BENEFITS_DEFAULT)
      .slice(0, 12).map((b) => ({
        icon: String((b && b.icon) || 'star.fill').slice(0, 30),
        title: String((b && b.title) || '').slice(0, 16),
        desc: String((b && b.desc) || '').slice(0, 60)
      }))
  };
}

function tierOf(id) {
  return memberCfg().tiers.find((t) => t.id === id) || null;
}

/** 这个人现在的会员状态（过期的就当普通用户） */
function memberOf(uid) {
  const rec = readMemberDb().users[uid];
  if (!rec || !rec.tier) return { tier: '', active: false, boost: 1 };
  const t = tierOf(rec.tier);
  if (!t) return { tier: '', active: false, boost: 1 };
  const exp = Number(rec.expireAt) || 0;
  const active = exp > Date.now();
  const days = active ? Math.max(0, Math.ceil((exp - Date.now()) / 86400000)) : 0;
  return {
    tier: t.id, name: t.name, short: t.short, color: t.color, color2: t.color2,
    expireAt: exp, active, daysLeft: days,
    autoRenew: !!rec.autoRenew,
    boost: active ? t.boost : 1,
    groupMax: active ? t.groupMax : 0
  };
}

/** 升级加速倍数（不是会员就是 1） */
function memberBoost(uid) {
  const m = memberOf(uid);
  return m.active ? m.boost : 1;
}

/** 下发到会话/用户里的那几个会员字段（不是会员就什么都不加） */
function memberFields(uid) {
  const m = memberOf(uid);
  if (!m.active) return {};
  return {
    memberTier: m.tier,
    memberShort: m.short,
    memberColor: m.color,
    memberColor2: m.color2
  };
}

/** 给某人开/续会员（days 天后到期；已经是会员就在原到期时间上接着加）
    price / months 只用来记账（零钱账单里那一行要显示金额） */
function setMember(uid, tierId, days, note, price, months) {
  const db = readMemberDb();
  const t = tierOf(tierId);
  if (!t) return null;
  const rec = db.users[uid] || { tier: '', expireAt: 0, autoRenew: false, history: [], totalDays: 0 };
  const base = Math.max(Number(rec.expireAt) || 0, Date.now());
  rec.tier = t.id;
  rec.expireAt = base + Math.max(1, Math.floor(days)) * 86400000;
  rec.totalDays = Math.round(((Number(rec.totalDays) || 0) + Math.max(1, Math.floor(days))) * 10) / 10;
  rec.updatedAt = now();
  rec.history = Array.isArray(rec.history) ? rec.history.slice(-50) : [];
  rec.history.push({
    at: now(), tier: t.id, days: Math.max(1, Math.floor(days)), expireAt: rec.expireAt,
    note: String(note || ''),
    price: Math.max(0, Math.round((Number(price) || 0) * 100) / 100),
    months: Math.max(0, Math.floor(Number(months) || 0))
  });
  db.users[uid] = rec;
  saveMemberDb();
  return memberOf(uid);
}

/** 会员有效期按天算：月=30 天、季=90、年=365 */
function monthsToDays(months) {
  const m = Math.max(1, Math.min(36, Math.floor(Number(months) || 1)));
  return m >= 12 ? m * 30 + Math.floor(m / 12) * 5 : m * 30;
}

/** 算钱：月/季/年三档单价里挑最划算的那个，再乘月数 */
function memberPrice(tier, months) {
  const m = Math.max(1, Math.min(36, Math.floor(Number(months) || 1)));
  const unit = m >= 12 ? (tier.price.year / 12) : (m >= 3 ? (tier.price.quarter / 3) : tier.price.month);
  return Math.round(unit * m * 100) / 100;
}

function memberHistoryOf(uid) {
  const rec = readMemberDb().users[uid];
  return (rec && Array.isArray(rec.history)) ? rec.history : [];
}

function noteMessage() {
  totalMessages += 1;
  msgTimes.push(Date.now());
  const cut = Date.now() - 60000;
  while (msgTimes.length && msgTimes[0] < cut) msgTimes.shift();
  const key = dayKey();
  if (dailyStats.day !== key) { dailyStats.day = key; dailyStats.messages = 0; }
  dailyStats.messages += 1;
  if (dailyStats.messages % 10 === 0) saveDailyStats();
}
function messagesPerMinute() { return msgTimes.length; }

/* ---------------------------------------------------------- 路由 */

async function handleOps(req, res, parts, query) {
  const method = req.method.toUpperCase();
  const sub = parts[1] || '';

  if (sub === 'login' && method === 'POST') {
    const body = await readBody(req);
    const username = str(body.username, 24).toLowerCase();
    const password = String(body.password || '');
    /* 后台密码不允许走明文 http（同网段抓包就拿到），本机除外。
       ⚠ 经过 TLS 前端（tlsproxy，本机回源 + X-Forwarded-Proto=https）的请求
       客户端那一段本来就是加密的，别误判成明文拒掉 —— 不然公网谁都登不进后台。 */
    const _rawPeerOps = String((req.socket && req.socket.remoteAddress) || '').replace('::ffff:', '');
    const _viaTlsFrontOps = /^(127\.0\.0\.1|::1)$/.test(_rawPeerOps)
      && String(req.headers['x-forwarded-proto'] || '').toLowerCase() === 'https';
    if (!req.socket.encrypted && !_viaTlsFrontOps
        && !/^(127\.0\.0\.1|::1)$/.test(peerIp(req))) {
      strikeIp(clientInfo(req).ip, '明文 HTTP 登录后台');
      audit(req, { username: username || '-', name: '未知', role: '-' }, '明文登录被拒', '', '要求改用 HTTPS');
      return fail(res, 403, httpsHint(req));
    }
    const kIp = 'ip:' + clientInfo(req).ip;
    const kUser = 'ops:' + username;
    /* 后台比普通登录更严：5 次错密码锁 30 分钟（账号和 IP 各算一遍） */
    const wait = Math.max(opsLoginBlocked(kUser), opsLoginBlocked(kIp), loginBlocked(kIp));
    if (wait) return fail(res, 429, '密码错误次数太多，请 ' + Math.ceil(wait / 60) + ' 分钟后再试');
    const admin = opsStore.admins.find((a) => a.username === username && !a.disabled);
    if (!admin || !verifySecretRecord({ salt: admin.salt, hash: admin.hash }, password)) {
      audit(req, { username: username || '-', name: '未知', role: '-' }, '登录失败', '', '账号或密码不对');
      noteLoginFail(kUser);
      noteLoginFail(kIp);
      noteOpsFail(kUser);
      noteOpsFail(kIp);
      return fail(res, 401, '账号或密码不正确');
    }
    clearLoginFails([kUser, kIp]);
    clearOpsFails([kUser, kIp]);
    admin.lastLoginAt = now();
    admin.lastIp = clientInfo(req).ip;
    saveOpsAdmins();
    audit(req, admin, '登录', '', 'IP ' + admin.lastIp);
    ok(res, { admin: opsMe(admin) }, {
      'Set-Cookie': OPS_COOKIE + '=' + encodeURIComponent(signOpsToken(admin, clientInfo(req).ip))
        + '; Path=/; HttpOnly; SameSite=Lax; Max-Age=' + Math.floor(OPS_SESSION_TTL_MS / 1000)
    });
    return;
  }

  if (sub === 'session' && method === 'GET') {
    const admin = currentOps(req);
    ok(res, { authenticated: !!admin, admin: admin ? opsMe(admin) : null });
    return;
  }

  if (sub === 'logout' && method === 'POST') {
    const admin = currentOps(req);
    if (admin) audit(req, admin, '退出登录', '', '');
    ok(res, { loggedOut: true }, { 'Set-Cookie': OPS_COOKIE + '=; Path=/; HttpOnly; Max-Age=0' });
    return;
  }

  const admin = currentOps(req);
  if (!admin) return fail(res, 401, '请先登录管理后台');

  /* ==========================================================================
     IM 后台（规范里的页面）：用户详情 / 处罚记录 / 消息投递 / 离线消息 /
     好友申请 / 黑名单 / 群成员与群消息 / 朋友圈评论 / 风控黑名单 /
     通话记录与统计 / 用户行为日志 / 运营配置（阈值·版本·告警）/ 角色权限
     数据源见上面 IMADMIN_FILE 那段说明（还是 data/*.json，没有引 MySQL）。
     ========================================================================== */
  const nm = (id) => { const u = findUser(id); return u ? (u.nickname || u.username || '') : '已注销'; };
  const uname = (id) => { const u = findUser(id); return u ? (u.username || '') : ''; };
  const maskPhone = (p) => {
    const s = String(p || '').replace(/\D/g, '');
    if (!s) return '';
    return s.length >= 7 ? (s.slice(0, 3) + '****' + s.slice(-4)) : s;
  };
  /* 处罚记录：封禁状态 + 风控临时限制 + 审计日志里的处罚动作，合成一份 */
  const punishmentsOf = (uid) => {
    const rows = [];
    const u = findUser(uid);
    if (u && u.banned) {
      rows.push({ type: '封禁', reason: u.banReason || '', at: u.bannedAt || '', until: '长期', admin: u.bannedBy || '—', ip: u.bannedIp || '' });
    }
    try {
      const rec = loadRiskStore().users[uid];
      if (rec && Number(rec.restrictUntil) > Date.now()) {
        rows.push({
          type: '风控临时限制', reason: Object.keys(rec.kinds || {}).join(' / ') || '风险评分过高',
          at: rec.updatedAt ? new Date(rec.updatedAt).toISOString() : '',
          until: new Date(rec.restrictUntil).toISOString(), admin: '系统自动（' + (rec.score || 0) + ' 分）', ip: ''
        });
      }
    } catch (err) { }
    try {
      const r = readAuditQuery({ limit: 400, q: '' });
      r.rows.filter((x) => x.target === uid || (u && x.target === u.username))
        .filter((x) => /封禁|解封|禁言|限制|警告|冻结|删除/.test(String(x.action || '')))
        .forEach((x) => rows.push({ type: x.action, reason: x.detail || '', at: x.at, until: '', admin: x.admin, ip: x.ip }));
    } catch (err) { }
    return rows.sort((a, b) => String(b.at).localeCompare(String(a.at)));
  };

  /* ---------- 用户详情（基础信息 + 登录设备/日志 + 好友 + 群 + 处罚） ---------- */
  if (sub === 'userdetail' && method === 'GET') {
    if (!can(admin, 'users')) return fail(res, 403, '你的角色没有查看用户的权限');
    const u = findUser(String(query.get('uid') || ''));
    if (!u) return fail(res, 404, '用户不存在');
    const logins = (db.security.logins || []).filter((l) => l.userId === u.id).slice(0, 50);
    const events = (db.security.events || []).filter((l) => l.userId === u.id).slice(0, 30);
    const devices = [];
    const seen = new Set();
    logins.forEach((l) => {
      const k = String(l.device || '未知设备');
      if (seen.has(k)) return;
      seen.add(k);
      devices.push({ device: k, lastIp: l.ip || '', lastAt: l.time });
    });
    ok(res, {
      user: publicUser(u),
      profile: {
        id: u.id, username: u.username, nickname: u.nickname, phone: maskPhone(u.phone), phoneRaw: u.phone || '',
        realName: u.realName || '', banned: !!u.banned, banReason: u.banReason || '', banCount: u.banCount || 0,
        createdAt: u.createdAt, lastLoginAt: logins.length ? logins[0].time : '', lastIp: logins.length ? logins[0].ip : '',
        lastDevice: logins.length ? logins[0].device : '', balance: Number(u.balance) || 0,
        friendCount: friendIds(u.id).length, chatCount: chatsOf(u.id).length
      },
      logins: logins.map((l) => ({ at: l.time, ip: l.ip || '', device: l.device || '', kind: l.kind || 'login' })),
      devices,
      events: events.map((l) => ({ at: l.time, kind: l.kind || '', ip: l.ip || '', device: l.device || '' })),
      friends: friendIds(u.id).map((id) => ({ id, nickname: nm(id), username: uname(id) })),
      groups: db.chats.filter((c) => c.type !== 'direct' && (c.memberIds || []).includes(u.id))
        .map((c) => ({ id: c.id, name: c.name || '', members: (c.memberIds || []).length })),
      punishments: punishmentsOf(u.id)
    });
    return;
  }

  /* ---------- 账号处罚记录（全站） ---------- */
  if (sub === 'punishments' && method === 'GET') {
    if (!can(admin, 'users')) return fail(res, 403, '你的角色没有查看处罚记录的权限');
    const limit = Math.min(300, Number(query.get('limit')) || 100);
    const rows = [];
    db.users.filter((u) => u.banned).forEach((u) => rows.push({
      userId: u.id, username: u.username, nickname: u.nickname, type: '封禁',
      reason: u.banReason || '', at: u.bannedAt || '', until: '长期', admin: u.bannedBy || '—', ip: u.bannedIp || ''
    }));
    try {
      const st = loadRiskStore();
      Object.keys(st.users || {}).forEach((id) => {
        const rec = st.users[id];
        if (!rec) return;
        if (Number(rec.restrictUntil) > Date.now()) {
          rows.push({
            userId: id, username: uname(id), nickname: nm(id), type: '风控临时限制',
            reason: Object.keys(rec.kinds || {}).join(' / ') || '风险评分过高',
            at: rec.updatedAt ? new Date(rec.updatedAt).toISOString() : '',
            until: new Date(rec.restrictUntil).toISOString(), admin: '系统自动（' + (rec.score || 0) + ' 分）', ip: ''
          });
        }
      });
    } catch (err) { }
    try {
      readAuditQuery({ limit: 400, q: '' }).rows
        .filter((x) => /封禁|解封|禁言|限制|警告/.test(String(x.action || '')))
        .forEach((x) => rows.push({
          userId: '', username: x.target || '', nickname: '', type: x.action,
          reason: x.detail || '', at: x.at, until: '', admin: x.admin, ip: x.ip
        }));
    } catch (err) { }
    rows.sort((a, b) => String(b.at).localeCompare(String(a.at)));
    ok(res, { rows: rows.slice(0, limit), total: rows.length });
    return;
  }

  /* ---------- 单聊会话列表（规范：会话ID / 双方用户ID / 创建时间 / 最后一条消息时间） ---------- */
  if (sub === 'chatlist' && method === 'GET') {
    if (!can(admin, 'messages')) return fail(res, 403, '你的角色没有查看会话的权限');
    const q = String(query.get('q') || '').trim();
    const page = Math.max(1, Number(query.get('page')) || 1);
    const pageSize = Math.min(50, Number(query.get('pageSize')) || 30);
    /* 会话类型：direct / single 都是一对一，group 才是群（数据里三种都存在） */
    let list = db.chats.filter((c) => c.type !== 'group');
    if (q) {
      const u = findUser(q);
      if (u) list = list.filter((c) => (c.memberIds || []).indexOf(u.id) >= 0);
    }
    list = list.slice().sort((a, b) => String(b.updatedAt || b.createdAt).localeCompare(String(a.updatedAt || a.createdAt)));
    ok(res, {
      rows: list.slice((page - 1) * pageSize, page * pageSize).map((c) => {
        const msgs = loadMessages(c.id);
        const last = msgs.length ? msgs[msgs.length - 1] : null;
        return {
          id: c.id,
          memberIds: c.memberIds || [],
          members: (c.memberIds || []).map((id) => ({ id, nickname: nm(id), username: uname(id) })),
          createdAt: c.createdAt,
          lastAt: last ? last.createdAt : '',
          messageCount: msgs.length
        };
      }),
      total: list.length, page, pageSize
    });
    return;
  }

  /* ---------- 消息投递日志（只给元数据，不给聊天明文） ---------- */
  if (sub === 'delivery' && method === 'GET') {
    if (!can(admin, 'messages')) return fail(res, 403, '你的角色没有查看消息投递的权限');
    const q = String(query.get('q') || '').trim();
    const limit = Math.min(200, Number(query.get('limit')) || 60);
    let chats = [];
    if (q) {
      const u = findUser(q);
      if (u) chats = chatsOf(u.id);
      else { const c = db.chats.find((x) => x.id === q); if (c) chats = [c]; }
    } else {
      chats = db.chats.slice().sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt))).slice(0, 12);
    }
    const rows = [];
    chats.slice(0, 20).forEach((c) => {
      loadMessages(c.id).slice(-limit).forEach((m) => {
        if (m.recalled) return;
        const receivers = (c.memberIds || []).filter((id) => id !== m.senderId);
        const readBy = receivers.filter((id) => Number((db.reads[id] || {})[c.id] || 0) >= Number(m.seq || 0));
        const deliveredBy = receivers.filter((id) => Number((db.delivered[id] || {})[c.id] || 0) >= Number(m.seq || 0));
        rows.push({
          id: m.id, chatId: c.id, chatType: c.type,
          fromId: m.senderId, from: nm(m.senderId), toIds: receivers, to: receivers.map(nm).join('、'),
          kind: m.kind || '', at: m.createdAt, seq: m.seq || 0,
          status: !receivers.length ? '已送达'
            : (readBy.length === receivers.length ? '已读'
              : (deliveredBy.length === receivers.length ? '已送达'
                : (deliveredBy.length ? '部分送达' : '未送达'))),
          deliveredCount: deliveredBy.length, readCount: readBy.length, receiverCount: receivers.length
        });
      });
    });
    rows.sort((a, b) => String(b.at).localeCompare(String(a.at)));
    ok(res, { rows: rows.slice(0, limit), note: '只给元数据（谁发给谁、时间、类型、投递状态），不含聊天内容', total: rows.length });
    return;
  }

  /* ---------- 离线消息查询（没读到的消息 + 堆积量） ---------- */
  if (sub === 'offline' && method === 'GET') {
    if (!can(admin, 'messages')) return fail(res, 403, '你的角色没有查看离线消息的权限');
    const u = findUser(String(query.get('uid') || ''));
    if (!u) return fail(res, 404, '用户不存在');
    const rows = [];
    let total = 0;
    chatsOf(u.id).forEach((c) => {
      const readSeq = Number((db.reads[u.id] || {})[c.id] || 0);
      const deliveredSeq = Number((db.delivered[u.id] || {})[c.id] || 0);
      const backlog = loadMessages(c.id).filter((m) => Number(m.seq || 0) > readSeq && m.senderId !== u.id);
      if (!backlog.length) return;
      total += backlog.length;
      const offline = backlog.filter((m) => Number(m.seq || 0) > deliveredSeq).length;
      rows.push({
        chatId: c.id, type: c.type, title: c.name || '',
        peer: c.type === 'direct' ? nm((c.memberIds || []).find((id) => id !== u.id) || '') : '',
        count: backlog.length, offline,
        oldest: backlog[0].createdAt, newest: backlog[backlog.length - 1].createdAt
      });
    });
    rows.sort((a, b) => b.count - a.count);
    ok(res, { user: { id: u.id, nickname: u.nickname, username: u.username }, online: onlineUserIds().includes(u.id), rows, total });
    return;
  }

  /* ---------- 好友申请列表 ---------- */
  if (sub === 'friendapply' && method === 'GET') {
    if (!can(admin, 'friends')) return fail(res, 403, '你的角色没有查看好友申请的权限');
    const pending = db.friendships.filter((f) => f.status === 'pending').map((f) => ({
      id: f.id, fromId: f.fromId, from: nm(f.fromId), toId: f.toId, to: nm(f.toId),
      at: f.createdAt, status: '待处理', note: f.message || ''
    }));
    const done = db.friendships.filter((f) => f.status === 'accepted')
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt))).slice(0, 80)
      .map((f) => ({ id: f.id, fromId: f.fromId, from: nm(f.fromId), toId: f.toId, to: nm(f.toId), at: f.createdAt, status: '已同意', note: '' }));
    ok(res, { pending, rows: pending.concat(done), total: db.friendships.length });
    return;
  }

  /* ---------- 黑名单管理（谁拉黑了谁） ---------- */
  if (sub === 'blocklist' && method === 'GET') {
    if (!can(admin, 'friends')) return fail(res, 403, '你的角色没有查看黑名单的权限');
    const rows = [];
    const byOwner = readFriendMeta().byOwner || {};
    Object.keys(byOwner).forEach((owner) => {
      const m = byOwner[owner] || {};
      Object.keys(m).forEach((otherId) => {
        if (m[otherId] && m[otherId].block === true) {
          rows.push({ ownerId: owner, owner: nm(owner), targetId: otherId, target: nm(otherId) });
        }
      });
    });
    ok(res, { rows: rows.slice(0, 500), total: rows.length });
    return;
  }
  if (sub === 'blocklist' && parts[2] === 'release' && method === 'POST') {
    if (!can(admin, 'friends.write')) return fail(res, 403, '你的角色没有解除拉黑的权限');
    const body = await readBody(req);
    const ownerId = str(body.ownerId, 40), targetId = str(body.targetId, 40);
    if (!findUser(ownerId) || !findUser(targetId)) return fail(res, 404, '用户不存在');
    setMeta(ownerId, targetId, { block: false });
    audit(req, admin, '解除拉黑', ownerId + ' → ' + targetId, '');
    ok(res, { released: true });
    return;
  }

  /* ---------- 群成员列表 / 群消息日志 ---------- */
  if (sub === 'groupmembers' && method === 'GET') {
    if (!can(admin, 'users') && !can(admin, 'messages')) return fail(res, 403, '你的角色没有查看群的权限');
    const c = db.chats.find((x) => x.id === String(query.get('gid') || ''));
    if (!c) return fail(res, 404, '群不存在');
    const admins = Array.isArray(c.adminIds) ? c.adminIds : [];
    const members = (c.memberIds || []).map((id) => {
      const u = findUser(id);
      return {
        id, nickname: u ? u.nickname : '已注销', username: u ? u.username : '',
        role: id === c.ownerId ? '群主' : (admins.indexOf(id) >= 0 ? '管理员' : '普通成员'),
        banned: !!(u && u.banned)
      };
    }).sort((a, b) => (a.role === '群主' ? -1 : b.role === '群主' ? 1 : (a.role === '管理员' ? -1 : b.role === '管理员' ? 1 : 0)));
    ok(res, {
      chat: { id: c.id, name: c.name || '', ownerId: c.ownerId || '', owner: nm(c.ownerId), members: members.length, createdAt: c.createdAt, muted: !!c.muted },
      members
    });
    return;
  }
  if (sub === 'groupmessages' && method === 'GET') {
    if (!can(admin, 'messages')) return fail(res, 403, '你的角色没有查看群消息的权限');
    const c = db.chats.find((x) => x.id === String(query.get('gid') || ''));
    if (!c) return fail(res, 404, '群不存在');
    const limit = Math.min(200, Number(query.get('limit')) || 80);
    const readStatusText = (readCount, total) => {
      if (!total) return '已送达';
      if (readCount >= total) return '全部已读';
      if (readCount > 0) return readCount + '/' + total + ' 已读';
      return '已送达';
    };
    const rows = loadMessages(c.id).slice(-limit).map((m) => {
      const receivers = (c.memberIds || []).filter((id) => id !== m.senderId);
      const readCount = receivers.filter((id) => Number((db.reads[id] || {})[c.id] || 0) >= Number(m.seq || 0)).length;
      return {
        id: m.id, fromId: m.senderId, from: nm(m.senderId), kind: m.kind || '', at: m.createdAt,
        delivered: receivers.length, read: readCount, recalled: !!m.recalled,
        status: readStatusText(readCount, receivers.length)
      };
    });
    ok(res, { chat: { id: c.id, name: c.name || '', members: (c.memberIds || []).length }, rows: rows.reverse(), note: '只给元数据，不含聊天明文' });
    return;
  }

  /* ---------- 朋友圈评论管理 ---------- */
  if (sub === 'momentcomments' && method === 'GET') {
    if (!can(admin, 'moments')) return fail(res, 403, '你的角色没有查看朋友圈的权限');
    const rows = [];
    (db.moments || []).forEach((m) => {
      (m.comments || []).forEach((c) => {
        rows.push({
          id: c.id, momentId: m.id, momentOwner: nm(m.userId), userId: c.userId, user: nm(c.userId),
          content: c.content || '', at: c.at, replyTo: c.replyTo || ''
        });
      });
    });
    rows.sort((a, b) => String(b.at).localeCompare(String(a.at)));
    ok(res, { rows: rows.slice(0, 300), total: rows.length });
    return;
  }
  if (sub === 'momentcomments' && parts[2] === 'del' && method === 'POST') {
    if (!can(admin, 'moments.write')) return fail(res, 403, '你的角色没有删除评论的权限');
    const body = await readBody(req);
    const cid = str(body.commentId, 60);
    let hit = null;
    (db.moments || []).forEach((m) => {
      const i = (m.comments || []).findIndex((c) => c.id === cid);
      if (i >= 0) { hit = (m.comments || [])[i]; m.comments.splice(i, 1); }
    });
    if (!hit) return fail(res, 404, '评论不存在');
    saveMoments();
    audit(req, admin, '删除朋友圈评论', nm(hit.userId), String(hit.content || '').slice(0, 60));
    ok(res, { deleted: true });
    return;
  }

  /* ---------- 风控黑名单（IP + 账号） ---------- */
  if (sub === 'blacklist' && method === 'GET') {
    if (!can(admin, 'risk')) return fail(res, 403, '你的角色没有查看风控黑名单的权限');
    const ips = [];
    ipBans.forEach((until, ip) => ips.push({ ip, until: new Date(until).toISOString(), remainMin: Math.max(0, Math.round((until - Date.now()) / 60000)) }));
    const restricted = [];
    const banned = [];
    db.users.filter((u) => u.banned).forEach((u) => banned.push({
      id: u.id, username: u.username, nickname: u.nickname, reason: u.banReason || '', at: u.bannedAt || ''
    }));
    try {
      const st = loadRiskStore();
      Object.keys(st.users || {}).forEach((id) => {
        const rec = st.users[id];
        if (rec && Number(rec.restrictUntil) > Date.now()) restricted.push({
          id, username: uname(id), nickname: nm(id), score: rec.score || 0,
          until: new Date(rec.restrictUntil).toISOString(), kinds: Object.keys(rec.kinds || {})
        });
      });
    } catch (err) { }
    ok(res, { ips, restricted, banned, note: 'IP 封禁来自自动防刷（连续失败/明文探测）；账号封禁见「账号处罚记录」' });
    return;
  }
  if (sub === 'blacklist' && method === 'POST') {
    if (!can(admin, 'risk.write')) return fail(res, 403, '你的角色没有改风控黑名单的权限');
    const body = await readBody(req);
    const ip = String(body.ip || '').replace(/[^0-9a-fA-F:.]/g, '').slice(0, 60);
    if (!ip) return fail(res, 400, 'IP 写错了');
    if (body.release) {
      ipBans.delete(ip);
      audit(req, admin, '解除 IP 封禁', ip, '');
      ok(res, { released: true });
    } else {
      const minutes = Math.min(10080, Math.max(1, Number(body.minutes) || 60));
      ipBans.set(ip, Date.now() + minutes * 60000);
      audit(req, admin, 'IP 封禁', ip, minutes + ' 分钟 · ' + (body.reason || ''));
      ok(res, { banned: true, ip, minutes });
    }
    return;
  }

  /* ---------- 通话记录 + 统计（通话结果本来就以系统消息写在会话里） ---------- */
  if (sub === 'calls' && method === 'GET') {
    if (!can(admin, 'messages')) return fail(res, 403, '你的角色没有查看通话记录的权限');
    const limit = Math.min(300, Number(query.get('limit')) || 100);
    const days = Math.min(60, Math.max(1, Number(query.get('days')) || 7));
    const since = Date.now() - days * 86400000;
    const rows = [];
    const pool = db.chats
      .filter((c) => c.type !== 'group' && Date.parse(c.updatedAt || 0) >= since)
      .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)))
      .slice(0, 800);
    pool.forEach((c) => {
      loadMessages(c.id).slice(-40).forEach((m) => {
        const kind = String(m.kind || '');
        if (kind !== 'system' && kind !== 'call' && kind !== 'voicecall' && kind !== 'videocall') return;
        const text = callRecordTextOf(String(m.content || ''));
        if (!/通话|无应答|已取消|拒接|忙碌|时长/.test(text)) return;
        const other = (c.memberIds || []).find((id) => id !== m.senderId) || '';
        const mm = text.match(/通话时长\s+(\d{1,2}):(\d{2})/);
        const connected = !!mm;
        rows.push({
          id: m.id, peerIds: [m.senderId, other], callerId: m.senderId, caller: nm(m.senderId),
          calleeId: other, callee: nm(other), video: /视频/.test(text) || kind === 'videocall',
          at: m.createdAt, durationSec: mm ? Number(mm[1]) * 60 + Number(mm[2]) : 0,
          result: connected ? '接通' : '未接通', reason: connected ? '' : text.replace(/^[\[【][^\]】]*[\]】]/, '').trim() || text.slice(0, 30)
        });
      });
    });
    rows.sort((a, b) => String(b.at).localeCompare(String(a.at)));
    const todayStart = new Date(); todayStart.setHours(0, 0, 0, 0);
    const todayRows = rows.filter((r) => Date.parse(r.at) >= todayStart.getTime());
    const okRows = todayRows.filter((r) => r.result === '接通');
    const failReasons = {};
    todayRows.filter((r) => r.result !== '接通').forEach((r) => {
      const k = r.reason || '其他';
      failReasons[k] = (failReasons[k] || 0) + 1;
    });
    ok(res, {
      rows: rows.slice(0, limit),
      stats: {
        rangeDays: days, total: rows.length, todayTotal: todayRows.length,
        todayConnected: okRows.length,
        successRate: todayRows.length ? Math.round(okRows.length / todayRows.length * 1000) / 10 : 0,
        avgDurationSec: okRows.length ? Math.round(okRows.reduce((a, r) => a + r.durationSec, 0) / okRows.length) : 0,
        failReasons
      },
      note: '通话记录来自会话里的系统消息（和微信一样：通话结束会在聊天里留一条记录）'
    });
    return;
  }

  /* ---------- 用户行为日志（注册 / 登录 / 改手机号 / 实名 / 支付密码错…） ---------- */
  if (sub === 'behavior' && method === 'GET') {
    if (!can(admin, 'users')) return fail(res, 403, '你的角色没有查看行为日志的权限');
    const uid = String(query.get('uid') || '');
    const limit = Math.min(300, Number(query.get('limit')) || 120);
    let rows = (db.security.events || []).concat(db.security.logins || []);
    if (uid) rows = rows.filter((r) => r.userId === uid);
    rows = rows.slice().sort((a, b) => String(b.time).localeCompare(String(a.time)));
    ok(res, {
      rows: rows.slice(0, limit).map((r) => ({
        userId: r.userId, username: uname(r.userId), kind: r.kind || 'login',
        at: r.time, ip: r.ip || '', device: r.device || ''
      })), total: rows.length,
      kinds: Array.from(new Set(rows.map((r) => r.kind || 'login')))
    });
    return;
  }

  /* ---------- 运营配置：风控阈值 ---------- */
  if (sub === 'thresholds' && method === 'GET') {
    if (!can(admin, 'ops')) return fail(res, 403, '你的角色没有查看运营配置的权限');
    const cfg = imAdminCfg().thresholds || {};
    ok(res, {
      thresholds: Object.assign({
        registerPerIpPerDay: 5,
        friendApplyPerDay: 30,
        msgPerMinute: 60,
        riskRestrictScore: 80,
        riskWatchScore: 30
      }, cfg),
      current: {
        msgPerMinute: Math.round(MSG_MAX_PER_WINDOW / (MSG_WINDOW_MS / 60000)),
        wsPerIp: WS_MAX_PER_IP,
        apiPerWindow: API_MAX_PER_WINDOW
      }
    });
    return;
  }
  if (sub === 'thresholds' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改运营配置的权限');
    const body = await readBody(req);
    const next = {
      registerPerIpPerDay: Math.max(1, Number(body.registerPerIpPerDay) || 5),
      friendApplyPerDay: Math.max(1, Number(body.friendApplyPerDay) || 30),
      msgPerMinute: Math.max(1, Number(body.msgPerMinute) || 60),
      riskRestrictScore: Math.max(1, Math.min(100, Number(body.riskRestrictScore) || 80)),
      riskWatchScore: Math.max(1, Math.min(100, Number(body.riskWatchScore) || 30))
    };
    saveImAdmin({ thresholds: next });
    audit(req, admin, '修改风控阈值', Object.keys(next).join(','), JSON.stringify(next));
    ok(res, { thresholds: next });
    return;
  }

  /* ---------- 运营配置：App 版本管理 ---------- */
  /* 地图：填高德的「Web 服务」Key（免费申请）→ 位置搜索就用高德的 POI */
  if (sub === 'geo' && method === 'GET') {
    if (!can(admin, 'ops')) return fail(res, 403, '你的角色没有查看的权限');
    const g = readGeo();
    ok(res, { amapKey: g.amapKey || '', hasKey: !!String(g.amapKey || '').trim() });
    return;
  }
  if (sub === 'geo' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改的权限');
    const body = await readBody(req);
    const saved = saveGeo({ amapKey: str(body.amapKey, 80) });
    audit(req, admin, '修改高德 Key', '地图', saved.amapKey ? '已配置' : '已清空');
    ok(res, { amapKey: saved.amapKey, hasKey: !!String(saved.amapKey).trim() });
    return;
  }

  if (sub === 'appversion' && method === 'GET') {
    if (!can(admin, 'ops')) return fail(res, 403, '你的角色没有查看版本配置的权限');
    /* 钱的地基自检：不碰真账号，用一个临时对象把「扣款 / 不能扣成负数 /
       幂等 / 对账」这几条当场跑一遍。返回 ok:false 的那条就是有问题。 */
    if (query && query.get('selftest') === '1') {
      const scratch = { id: 'selftest_' + Date.now(), balance: 100, nickname: '自检' };
      const r1 = applyMoney(scratch, 50, { reason: '自检（不是真钱）' });
      const r2 = applyMoney(scratch, -500, { reason: '自检（不是真钱）' });        // 应该被拒
      const r3 = applyMoney(scratch, -30.005, { reason: '自检（不是真钱）' });      // 应该只扣 30.01 或 30
      const k = 'selftest:' + Date.now();
      const a = idemBegin(scratch, { requestId: k }, 'selftest');
      const b = idemBegin(scratch, { requestId: k }, 'selftest');       // 应该 dup + inflight
      idemFinish(a.key, { hello: 'world' });
      const c = idemBegin(scratch, { requestId: k }, 'selftest');       // 应该 dup + 拿到缓存
      const checks = [
        { name: '加钱', ok: r1.balance === 150, got: r1 },
        { name: '不许扣成负数', ok: !!r2.error, got: r2 },
        { name: '分厘不差（四舍五入到分）', ok: Number.isInteger(Math.round(r3.balance * 100)), got: r3 },
        { name: '第一次不重复', ok: a.dup !== true, got: { key: a.key } },
        { name: '重发时拦住（处理中）', ok: b.dup === true && b.inflight === true, got: b },
        { name: '重发时返回上次结果', ok: c.dup === true && c.cached && c.cached.hello === 'world', got: c.cached }
      ];
      /* 自检不留痕迹：幂等表删掉这次测试的键，快照里删掉这个临时账号。
         总账是追加写的、删不掉，但每行都带「自检」字样，接真钱对账时一眼能认出来。 */
      delete idemStore.items[a.key];
      idemSave();
      try {
        const st = readJson(path.join(DATA_DIR, MONEY_STATE), { users: {} });
        if (st.users && st.users[scratch.id]) {
          delete st.users[scratch.id];
          writeJson(path.join(DATA_DIR, MONEY_STATE), st);
        }
      } catch (err) { /* 清不掉也无所谓，自检账号不在真实用户表里 */ }
      return ok(res, { allOk: checks.every((x) => x.ok), checks: checks });
    }
    ok(res, {
      version: Object.assign({
        version: '', notes: '', force: false, url: 'https://aa.x8iu.com/Luchat.ipa', downloadPage: 'https://aa.x8iu.com'
      }, imAdminCfg().version || {})
    });
    return;
  }
  if (sub === 'appversion' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改版本配置的权限');
    const body = await readBody(req);
    const next = {
      version: str(body.version, 24), notes: String(body.notes || '').slice(0, 500),
      force: !!body.force, url: str(body.url, 200) || 'https://aa.x8iu.com/Luchat.ipa',
      downloadPage: str(body.downloadPage, 200) || 'https://aa.x8iu.com'
    };
    saveImAdmin({ version: next });
    audit(req, admin, '修改 App 版本配置', next.version, '强制更新=' + (next.force ? '是' : '否'));
    ok(res, { version: next });
    return;
  }

  /* ---------- 运营配置：App 弹窗公告 ----------
     和「全站公告消息」不是一回事：这里是 App 打开时弹的那个框（标题/内容/弹窗类型/
     生效时间/版本范围），存 imadmin.json，App 端通过 /api/version 的 notice 字段拿到。 */
  /* ---------- 全站公告消息（新后台也走这一套；老后台 /api/admin/broadcast 还在） ---------- */
  if (sub === 'announcements' && method === 'GET') {
    if (!can(admin, 'ops')) return fail(res, 403, '你的角色没有查看公告的权限');
    ok(res, { announcements: db.announcements.slice(0, 50) });
    return;
  }
  /* 应用名/启动页那套（branding）在老后台是 /api/admin/branding：
     新后台也补一个只读入口，页面要展示时不用再跳老后台。写入口仍在老后台，避免两头改。 */
  if (sub === 'branding' && method === 'GET') {
    if (!can(admin, 'icons')) return fail(res, 403, '你的角色没有查看应用配置的权限');
    ok(res, { branding: db.branding });
    return;
  }
  if (sub === 'broadcast' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有发公告的权限');
    const body = await readBody(req);
    const content = str(body.content, 300);
    if (!content) return fail(res, 422, '公告内容不能为空');
    let chats = 0;
    db.chats.forEach((chat) => {
      chat.seq = (chat.seq || 0) + 1;
      const message = {
        id: uid('m'), chatId: chat.id, seq: chat.seq, senderId: 'system',
        kind: 'system', content, createdAt: now(), recalled: false
      };
      appendMessage(chat.id, message);
      (chat.memberIds || []).forEach((id) => {
        sendTo(id, { type: 'message', message, chat: chatSummary(chat, id), clientId: null });
      });
      chats += 1;
    });
    saveChats();
    db.announcements.unshift({ id: uid('an'), content, createdAt: now(), chats });
    db.announcements = db.announcements.slice(0, 50);
    saveAnnouncements();
    audit(req, admin, '全站公告', content.slice(0, 40), '送达 ' + chats + ' 个会话');
    ok(res, { sent: true, chats });
    return;
  }

  if (sub === 'notice' && method === 'GET') {
    if (!can(admin, 'ops')) return fail(res, 403, '你的角色没有查看公告配置的权限');
    ok(res, {
      notice: Object.assign({
        enabled: false, title: '', content: '', kind: 'popup',
        startAt: '', endAt: '', minVersion: '', maxVersion: ''
      }, imAdminCfg().notice || {})
    });
    return;
  }
  if (sub === 'notice' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改公告配置的权限');
    const body = await readBody(req);
    const next = {
      enabled: !!body.enabled,
      title: String(body.title || '').slice(0, 60),
      content: String(body.content || '').slice(0, 1000),
      kind: String(body.kind || 'popup').slice(0, 20),
      startAt: String(body.startAt || '').slice(0, 30),
      endAt: String(body.endAt || '').slice(0, 30),
      minVersion: String(body.minVersion || '').slice(0, 20),
      maxVersion: String(body.maxVersion || '').slice(0, 20)
    };
    saveImAdmin({ notice: next });
    audit(req, admin, '修改弹窗公告', next.title, '启用=' + (next.enabled ? '是' : '否'));
    ok(res, { notice: next });
    return;
  }

  /* ---------- 系统设置：告警配置 ---------- */
  if (sub === 'alerts' && method === 'GET') {
    if (!can(admin, 'ops')) return fail(res, 403, '你的角色没有查看告警配置的权限');
    const monitor = readJson(path.join(DATA_DIR, 'monitor-config.json'), {}) || {};
    ok(res, {
      alerts: Object.assign({
        receivers: '', method: 'webhook', webhookUrl: monitor.webhookUrl || '',
        apiErrRatePct: 5, cpuPct: 80, memPct: 85, msgFailRatePct: 3, offlineMin: 2
      }, imAdminCfg().alerts || {}),
      monitor: { intervalSec: monitor.intervalSec || 15, failThreshold: monitor.failThreshold || 3, keepHours: monitor.keepHours || 72 },
      recent: (() => {
        try {
          const p = path.join(DATA_DIR, 'monitor-alerts.log');
          return fs.readFileSync(p, 'utf8').trim().split('\n').slice(-20).reverse();
        } catch (err) { return []; }
      })()
    });
    return;
  }
  if (sub === 'alerts' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改告警配置的权限');
    const body = await readBody(req);
    const next = {
      receivers: String(body.receivers || '').slice(0, 200),
      method: String(body.method || 'webhook').slice(0, 20),
      webhookUrl: String(body.webhookUrl || '').slice(0, 300),
      apiErrRatePct: Math.max(1, Number(body.apiErrRatePct) || 5),
      cpuPct: Math.max(10, Number(body.cpuPct) || 80),
      memPct: Math.max(10, Number(body.memPct) || 85),
      msgFailRatePct: Math.max(1, Number(body.msgFailRatePct) || 3),
      offlineMin: Math.max(1, Number(body.offlineMin) || 2)
    };
    saveImAdmin({ alerts: next });
    /* webhook 同时写进监测配置：看门狗挂了就按这个地址告警 */
    try {
      const mf = path.join(DATA_DIR, 'monitor-config.json');
      const cur = readJson(mf, {}) || {};
      cur.webhookUrl = next.webhookUrl;
      writeJson(mf, cur);
    } catch (err) { }
    audit(req, admin, '修改告警配置', next.method, next.receivers);
    ok(res, { alerts: next });
    return;
  }

  /* ---------- 系统设置：角色权限配置 ---------- */
  /* ---------- 系统设置：后台访问白名单（严格模式：不在名单里一律 404，不给提示） ---------- */
  if (sub === 'whitelist' && method === 'GET') {
    if (!can(admin, 'admins')) return fail(res, 403, '你的角色没有查看白名单的权限');
    ok(res, {
      ips: adminWhitelist(),
      myIp: clientInfo(req).ip,
      alwaysAllowed: ['127.0.0.1'],
      strict: adminWhitelist().length > 0,
      note: '名单为空时退回老规则（局域网 + 只允许国内）；一旦名单里有 IP，就只有名单里的能进后台，其它一律 404'
    });
    return;
  }
  if (sub === 'whitelist' && method === 'POST') {
    if (admin.role !== 'super') return fail(res, 403, '只有超级管理员能改访问白名单');
    const body = await readBody(req);
    const add = String(body.add || '').trim();
    const remove = String(body.remove || '').trim();
    let list = adminWhitelist();
    if (Array.isArray(body.ips)) list = body.ips.map((x) => String(x));
    if (add) list = list.concat([add]);
    if (remove) list = list.filter((x) => x !== remove);
    const next = saveAdminWhitelist(list);
    audit(req, admin, '改后台访问白名单', add || remove || '整表替换', next.join(', ').slice(0, 200));
    ok(res, { ips: next, myIp: clientInfo(req).ip, strict: next.length > 0 });
    return;
  }

  if (sub === 'roles' && method === 'GET') {
    if (!can(admin, 'admins')) return fail(res, 403, '你的角色没有查看角色权限的权限');
    ok(res, {
      roles: rolePerms(),
      defaults: OPS_ROLES,
      names: OPS_ROLE_NAMES,
      allPerms: Array.from(new Set(Object.keys(OPS_ROLES).reduce((acc, r) => acc.concat(OPS_ROLES[r]), []))).sort(),
      custom: !!(imAdminCfg().roles)
    });
    return;
  }
  if (sub === 'roles' && method === 'POST') {
    if (admin.role !== 'super') return fail(res, 403, '只有超级管理员能改角色权限');
    const body = await readBody(req);
    if (body.reset) {
      const next = Object.assign({}, imAdminCfg());
      delete next.roles;
      imAdminCache = next;
      try { writeJson(IMADMIN_FILE, next); } catch (err) { }
      audit(req, admin, '重置角色权限', '全部角色', '恢复默认');
      ok(res, { roles: OPS_ROLES, defaults: OPS_ROLES });
      return;
    }
    const roles = {};
    const src = body.roles && typeof body.roles === 'object' ? body.roles : {};
    ['super', 'auditor', 'support', 'ops'].forEach((r) => {
      const list = Array.isArray(src[r]) ? src[r] : (OPS_ROLES[r] || []);
      roles[r] = list.map((x) => String(x)).filter(Boolean).slice(0, 80);
    });
    roles.super = Array.from(new Set((OPS_ROLES.super || []).concat(roles.super)));
    saveImAdmin({ roles });
    audit(req, admin, '修改角色权限', '全部角色', JSON.stringify(roles).slice(0, 300));
    ok(res, { roles });
    return;
  }

  /* 界面配置类（UI 图标 / 发现页 / 我的页 / 界面文字 / 状态面板 / 表情 / 礼物 / +面板 / 应用名 / 图标上传）
     只有「超级管理员」能看能改 —— 客服、审核员、运维这些角色连读都读不到。 */
  const UI_SUBS = ['icons', 'discover', 'mepage', 'service', 'wallet', 'balance-page', 'bills-page', 'uiconfig', 'statuses', 'stickers', 'gifts', 'plus-panel', 'branding', 'upload', 'loginpage', 'badges', 'endpoints'];
  if (UI_SUBS.indexOf(sub) >= 0 && admin.role !== 'super') {
    return fail(res, 403, '界面配置只有超级管理员能看和改');
  }

  /* ---------------- 风控面板：评分榜 + 证据流 + 待复核 ---------------- */
  if (sub === 'risk' && method === 'GET') {
    if (!can(admin, 'risk')) return fail(res, 403, '你的角色没有查看风控的权限');
    ok(res, {
      board: riskBoard(100),
      events: riskEventsTail(120),
      approvals: opsStore.approvals.slice(0, 50),
      dualReview: !!opsStore.dualReview,
      scores: RISK_DELTA,
      levels: { watch: 30, restrict30m: 60, restrict24h: 80 }
    });
    return;
  }

  /* 人工解除临时限制（评分清零 + 撤掉限功能）——身份不对造成的误伤，管理员可以放行 */
  if (sub === 'risk' && parts[2] === 'release' && method === 'POST') {
    if (!can(admin, 'risk.write')) return fail(res, 403, '你的角色没有处置风控的权限');
    const body = await readBody(req);
    const targetId = str(body.userId, 40);
    const rec = loadRiskStore().users[targetId];
    if (!rec) return fail(res, 404, '这个账号没有风控记录');
    const before = Math.round(rec.score || 0);
    rec.score = Math.max(0, Number(body.score) || 0);   // 不传就是直接清零
    rec.restrictUntil = 0;
    if (rec.score === 0) rec.kinds = {};
    rec.updatedAt = Date.now();
    saveRiskStore();
    const u = findUser(targetId);
    audit(req, admin, '解除风控限制', (u && u.username) || targetId, '原评分 ' + before + ' → ' + rec.score);
    ok(res, { released: true, score: rec.score });
    return;
  }

  /* ---------------- 高危操作闸门：二次确认（+ 双人复核） ---------------- */
  const opPath = '/api/' + parts.join('/');
  const danger = req.__opsApproved ? null : dangerousOpOf(method, opPath);
  if (danger) {
    let dangerBody = {};
    try { dangerBody = await readBody(req); } catch (e) { dangerBody = {}; }
    if (!opsConfirmOk(admin, dangerBody)) {
      audit(req, admin, '高危操作被拦（密码没对上）', danger.label, opPath);
      return fail(res, 428, '这是高危操作「' + danger.label + '」，请再输入一次你自己的后台密码确认');
    }
    if (opsStore.dualReview && DUAL_REVIEW_LABELS.indexOf(danger.label) >= 0) {
      const pend = {
        id: uid('apv'), at: now(),
        byId: admin.id, by: admin.username, byName: admin.name, role: admin.role,
        label: danger.label, method, path: opPath, parts: parts.slice(),
        body: sanitizeApprovalBody(dangerBody),   // 落盘的只有脱敏参数，明文密码不留档
        ip: clientInfo(req).ip, status: 'pending',
        decidedBy: '', decidedAt: 0, note: ''
      };
      pendingOpBodies.set(pend.id, Object.assign({}, dangerBody, { confirmPassword: '' }));
      opsStore.approvals.unshift(pend);
      pruneApprovals();
      saveApprovals();
      audit(req, admin, '提交高危操作待复核', danger.label, pend.id + ' · ' + opPath);
      return ok(res, {
        pendingApproval: pend.id,
        needSecondAdmin: true,
        label: danger.label,
        hint: '已经提交复核：需要另一个管理员在「风控引擎 → 双人复核」里用他自己的密码批准后才执行'
      });
    }
    audit(req, admin, '高危操作二次确认通过', danger.label, opPath);
  }

  /* ---------------- 双人复核工单 ---------------- */
  if (sub === 'approvals' && method === 'GET') {
    if (!canSeeApprovals(admin)) return fail(res, 403, '你的角色没有查看复核工单的权限');
    const others = opsStore.admins.filter((a) => !a.disabled && a.id !== admin.id).length;
    ok(res, {
      enabled: !!opsStore.dualReview,
      others,
      approvals: opsStore.approvals.slice(0, 100),
      labels: DUAL_REVIEW_LABELS
    });
    return;
  }

  /* 开关本身也是敏感动作：只有超管能改，开启时必须先有两个后台账号 */
  if (sub === 'approvals' && parts[2] === 'settings' && method === 'POST') {
    if (admin.role !== 'super') return fail(res, 403, '只有超级管理员能改双人复核开关');
    const body = await readBody(req);
    if (body.enabled) {
      const others = opsStore.admins.filter((a) => !a.disabled && a.id !== admin.id).length;
      if (others < 1) return fail(res, 422, '至少要有两个后台账号才能开启双人复核（现在只有你一个，开了谁都批不了）');
      if (!opsConfirmOk(admin, body)) return fail(res, 428, '开启双人复核需要再输入一次你的后台密码');
    }
    opsStore.dualReview = !!body.enabled;
    saveOpsAdmins();
    audit(req, admin, opsStore.dualReview ? '开启双人复核' : '关闭双人复核', '', '');
    ok(res, { enabled: !!opsStore.dualReview });
    return;
  }

  if (sub === 'approvals' && parts[2] && (parts[3] === 'approve' || parts[3] === 'reject') && method === 'POST') {
    if (!canSeeApprovals(admin)) return fail(res, 403, '你的角色没有复核权限');
    const pend = opsStore.approvals.find((x) => x.id === parts[2]);
    if (!pend) return fail(res, 404, '复核单不存在');
    if (pend.status !== 'pending') return fail(res, 409, '这张复核单已经处理过了');
    const body = await readBody(req);
    if (!opsConfirmOk(admin, body)) return fail(res, 428, '复核需要再输入一次你自己的后台密码');
    if (pend.byId === admin.id) return fail(res, 403, '不能自己批准自己提交的高危操作，请让另一个管理员来批');
    if (parts[3] === 'reject') {
      pend.status = 'rejected';
      pend.decidedBy = admin.username;
      pend.decidedAt = now();
      pend.note = str(body.note, 120) || '复核驳回';
      saveApprovals();
      audit(req, admin, '驳回高危操作', pend.label, pend.id + ' · 申请人 ' + pend.by);
      ok(res, { approved: false, label: pend.label });
      return;
    }
    /* 批准：把原请求原样重放一次，这次带上「已复核」标记，闸门直接放行 */
    const rawBody = pendingOpBodies.get(pend.id);
    if (!rawBody) {
      return fail(res, 409, '这一单的原始参数已经不在了（服务器重启过），请让申请人重新提交一次');
    }
    pend.status = 'approved';
    pend.decidedBy = admin.username;
    pend.decidedAt = now();
    saveApprovals();
    audit(req, admin, '复核通过高危操作', pend.label, pend.id + ' · 申请人 ' + pend.by);
    const replay = {
      method: pend.method,
      headers: req.headers,
      socket: req.socket,
      __bodyPromise: Promise.resolve(rawBody),
      __opsApproved: pend.id,
      __opsApprover: admin.username
    };
    try {
      await handleOps(replay, res, pend.parts, new URLSearchParams());
    } catch (e) {
      if (!res.headersSent) return fail(res, 500, '复核通过了，但执行时报错：' + ((e && e.message) || e));
    }
    pendingOpBodies.delete(pend.id);
    return;
  }

  /* ---------------- 仪表盘 ---------------- */
  if (sub === 'dashboard' && method === 'GET') {
    if (!can(admin, 'dashboard')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const nowMs = Date.now();
    const day0 = localDayStart();
    const today = db.security.logins.filter((l) => nowMs - new Date(l.time).getTime() < 86400000);
    const newUsersToday = db.users.filter((u) => new Date(u.createdAt).getTime() >= day0).length;
    const transfersToday = db.transfers.filter((t) => new Date(t.createdAt).getTime() >= day0);
    const todayAmount = Math.round(transfersToday.reduce((a, t) => a + (Number(t.amount) || 0), 0) * 100) / 100;
    const todayMsgs = dailyStats.day === dayKey() ? dailyStats.messages : 0;
    // 异常交易：单笔 ≥2000、或者同一对人今天来回转账 ≥3 笔
    const pairCount = {};
    transfersToday.forEach((t) => {
      const k = [t.fromId, t.toId].sort().join('|');
      pairCount[k] = (pairCount[k] || 0) + 1;
    });
    const abnormal = transfersToday.filter((t) => Number(t.amount) >= 2000
      || (pairCount[[t.fromId, t.toId].sort().join('|')] || 0) >= 3).slice(0, 8).map((t) => ({
      id: t.id,
      amount: t.amount,
      at: t.createdAt,
      status: t.status,
      from: (findUser(t.fromId) || {}).nickname || '—',
      to: (findUser(t.toId) || {}).nickname || '—',
      reason: Number(t.amount) >= 2000 ? '单笔大额' : '短时间多次转账'
    }));
    const unhandledVio = opsStore.violations.filter((v) => !v.handled).length;
    const openReports = opsStore.reports.filter((r) => r.status === 'open').length;
    /* 客服工单：没处理的有几条（后台菜单上挂个小数字） */
    const pendingSupport = readSupportTickets(500).filter((t) => (t.status || 'pending') === 'pending').length;
    const mem = process.memoryUsage();
    ok(res, {
      stats: {
        users: db.users.length,
        online: onlineUserIds().length,
        bots: db.users.filter((u) => u.bot).length,
        banned: db.users.filter((u) => u.banned).length,
        chats: db.chats.length,
        messages: totalMessages,
        msgPerMin: messagesPerMinute(),
        friends: db.friendships.filter((f) => f.status === 'accepted').length,
        pendingFriends: db.friendships.filter((f) => f.status === 'pending').length,
        moments: db.moments.length,
        transfers: db.transfers.length,
        logins24h: today.length,
        violations: unhandledVio,
        reports: openReports,
        newUsersToday,
        messagesToday: todayMsgs,
        transfersToday: transfersToday.length,
        amountToday: todayAmount,
        abnormal: abnormal.length,
        support: pendingSupport
      },
      health: {
        uptime: Math.round(process.uptime()),
        memoryMB: Math.round(mem.rss / 1024 / 1024),
        heapMB: Math.round(mem.heapUsed / 1024 / 1024),
        node: process.version,
        dataDir: DATA_DIR
      },
      alerts: opsStore.violations.filter((v) => !v.handled).slice(0, 8).map((v) => ({
        at: v.at, who: v.nickname || v.username, word: v.word, content: v.content
      })),
      abnormal,
      recentLogins: today.slice(0, 8).map((l) => ({
        time: l.time, ip: l.ip, device: l.device, user: (findUser(l.userId) || {}).nickname || l.userId
      }))
    });
    return;
  }

  /* ---------------- 用户管理 ---------------- */
  /* ---------------- 登录页外观（颜色 / 背景图 / 图标 / 文案）---------------- */
  const LOGIN_DEFAULT = {
    accent: '#07C160', bg: '#f2f3f5', card: '#ffffff', text: '#181818', sub: '#8a8f99',
    bgImage: '', logo: '', appName: '', subTitle: '', darkAccent: '#07C160', darkBg: '#111214', darkCard: '#1c1c1e', darkText: '#eceff3',
    /* App 登录页用的（手机号登录那条蓝色、禁用色） */
    accent2: '#007AFF', disabledAccent: '#B2E4C8', disabledGray: '#C7C7CC', pageBg: '',
    /* 用户协议 / 隐私政策全文（后台可编辑） */
    terms: ['1. 本应用是自建的即时通讯软件，账号与数据都保存在你自己的服务器上。',
      '2. 请勿使用本应用传播违法违规内容；一经发现，管理员有权封禁账号。',
      '3. 你的昵称、头像、朋友圈等资料仅用于本应用内的展示，不会提供给第三方。',
      '4. 聊天内容保存在你自己的服务器数据库中，用于在登录设备之间同步。',
      '5. 修改密码后，之前的登录令牌会立即失效，需要重新登录。',
      '6. 如不同意以上条款，请不要使用本应用。'].join('\n'),
    privacy: ['1. 我们收集的信息：昵称、头像、地区、个性签名，以及你主动发送的消息与图片。',
      '2. 信息用途：仅用于在本应用内展示和在你的登录设备之间同步。',
      '3. 存储位置：全部保存在你自己的服务器上，不会上传到任何第三方服务。',
      '4. 分享范围：你的朋友圈对好友可见；聊天内容仅你与对方可见。',
      '5. 你的权利：可以随时修改资料、换头像、清空聊天记录，或要求管理员删除账号。',
      '6. 安全措施：账号密码加密存储、登录令牌加密签名、后台操作全程审计。'].join('\n')
  };
  /* 红点提醒：后台逐个位置设置 */
  if (sub === 'badges' && method === 'GET') {
    ok(res, { badges: Object.assign({}, BADGE_DEFAULT, db.badges || {}), defaults: BADGE_DEFAULT, keys: BADGE_KEYS, values: BADGE_VALUES });
    return;
  }
  if (sub === 'badges' && method === 'POST') {
    const body = await readBody(req);
    const next = Object.assign({}, BADGE_DEFAULT, db.badges || {});
    BADGE_KEYS.forEach((k) => {
      const v = str(body[k], 8);
      if (BADGE_VALUES.indexOf(v) >= 0) next[k] = v;
    });
    db.badges = next;
    saveBadges();
    audit(req, admin, '修改红点提醒', '-', JSON.stringify(next));
    ok(res, { badges: next });
    return;
  }

  /* 线路入口：App 端的「主入口 + 备用入口」。线上线路被掐时，App 自动按这份列表换地址，
     后台改完立即生效（App 每次进前台会重新拉一次），不用重新装包。 */
  if (sub === 'endpoints' && method === 'GET') {
    const cfg = readJson(ENDPOINTS_FILE, null);
    ok(res, {
      endpoints: serverEndpoints(),
      defaults: DEFAULT_ENDPOINTS.slice(),
      saved: !!(cfg && Array.isArray(cfg.endpoints) && cfg.endpoints.length)
    });
    return;
  }
  if (sub === 'endpoints' && method === 'POST') {
    const body = await readBody(req);
    const list = (Array.isArray(body.endpoints) ? body.endpoints : [])
      .map(normalizeEndpoint).filter(Boolean).slice(0, 6);
    writeJson(ENDPOINTS_FILE, { endpoints: list, updatedAt: new Date().toISOString() });
    audit(req, admin, '改服务器入口', list.join(' / ') || '(清空)', '');
    ok(res, { endpoints: list.length ? list : DEFAULT_ENDPOINTS.slice() });
    return;
  }

  if (sub === 'loginpage' && method === 'GET') {
    const cur = (db.branding && db.branding.login) || {};
    ok(res, { login: Object.assign({}, LOGIN_DEFAULT, cur), defaults: LOGIN_DEFAULT });
    return;
  }
  if (sub === 'loginpage' && method === 'POST') {
    const body = await readBody(req);
    const cur = (db.branding && db.branding.login) || {};
    const hex = (v, dft) => {
      const s = str(v, 9).trim();
      return /^#[0-9a-fA-F]{6}$/.test(s) ? s.toUpperCase() : dft;
    };
    const imgRef = (v, dft) => {
      const s = str(v, 2000).trim();
      if (!s) return '';
      const safe = safeImageRef(s);
      return safe === null ? dft : safe;
    };
    const next = {
      accent: hex(body.accent, LOGIN_DEFAULT.accent),
      bg: hex(body.bg, LOGIN_DEFAULT.bg),
      card: hex(body.card, LOGIN_DEFAULT.card),
      text: hex(body.text, LOGIN_DEFAULT.text),
      sub: hex(body.sub, LOGIN_DEFAULT.sub),
      darkAccent: hex(body.darkAccent, LOGIN_DEFAULT.darkAccent),
      darkBg: hex(body.darkBg, LOGIN_DEFAULT.darkBg),
      darkCard: hex(body.darkCard, LOGIN_DEFAULT.darkCard),
      darkText: hex(body.darkText, LOGIN_DEFAULT.darkText),
      /* 这几个字段「没传」就保留原来的值 —— 否则每次保存都会把背景图/图标/名字清空 */
      bgImage: body.bgImage === undefined ? String(cur.bgImage || '') : imgRef(body.bgImage, ''),
      logo: body.logo === undefined ? String(cur.logo || '') : imgRef(body.logo, ''),
      appName: body.appName === undefined ? String(cur.appName || '') : str(body.appName, 20),
      subTitle: body.subTitle === undefined ? String(cur.subTitle || '') : str(body.subTitle, 30),
      accent2: hex(body.accent2, LOGIN_DEFAULT.accent2),
      disabledAccent: hex(body.disabledAccent, LOGIN_DEFAULT.disabledAccent),
      disabledGray: hex(body.disabledGray, LOGIN_DEFAULT.disabledGray),
      pageBg: body.pageBg ? hex(body.pageBg, '') : '',
      terms: body.terms === undefined ? (cur && cur.terms) || LOGIN_DEFAULT.terms : str(body.terms, 20000),
      privacy: body.privacy === undefined ? (cur && cur.privacy) || LOGIN_DEFAULT.privacy : str(body.privacy, 20000)
    };
    db.branding.login = next;
    /* 应用名一处改、全站生效：登录页的名字也同步成全局应用名 */
    if (next.appName) db.branding.appName = next.appName;
    db.branding.updatedAt = now();
    saveBranding();
    audit(req, admin, '修改登录页外观', 'loginpage', '主色 ' + next.accent + (next.bgImage ? ' · 带背景图' : ''));
    ok(res, { login: next });
    return;
  }

  if (sub === 'users' && method === 'GET' && parts.length === 2) {
    if (!can(admin, 'users')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const q = str(query.get('q'), 40).toLowerCase();
    let list = db.users.slice();
    if (q) {
      list = list.filter((u) => String(u.username).toLowerCase().indexOf(q) >= 0
        || String(u.nickname || '').toLowerCase().indexOf(q) >= 0
        || String(u.phone || '').indexOf(q) >= 0
        || String(u.id) === q);
    }
    list.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    const limit = Math.min(200, Math.max(1, Number(query.get('limit')) || 50));
    const online = onlineUserIds();
    ok(res, {
      total: list.length,
      users: list.slice(0, limit).map((u) => Object.assign(publicUser(u), {
        phone: u.phone || '',
        balance: Number(u.balance) || 0,
        banned: !!u.banned,
        banReason: u.banReason || '',
        online: online.indexOf(u.id) >= 0,
        friendCount: db.friendships.filter((f) => f.status === 'accepted'
          && (f.fromId === u.id || f.toId === u.id)).length,
        chatCount: db.chats.filter((c) => c.memberIds.indexOf(u.id) >= 0).length
      }))
    });
    return;
  }

  if (sub === 'users' && parts.length === 3 && method === 'GET') {
    if (!can(admin, 'users')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const u = findUser(parts[2]);
    if (!u) return fail(res, 404, '用户不存在');
    audit(req, admin, '查看用户详情', u.username, u.id);
    const logins = db.security.logins.filter((l) => l.userId === u.id).slice(0, 20);
    const friends = db.friendships.filter((f) => f.status === 'accepted'
      && (f.fromId === u.id || f.toId === u.id)).map((f) => {
      const other = findUser(f.fromId === u.id ? f.toId : f.fromId);
      return other ? { id: other.id, username: other.username, nickname: other.nickname, avatar: other.avatar || '' } : null;
    }).filter(Boolean);
    const chats = db.chats.filter((c) => c.memberIds.indexOf(u.id) >= 0).map((c) => chatSummary(c, u.id));
    ok(res, {
      user: Object.assign(publicUser(u), {
        phone: u.phone || '', balance: Number(u.balance) || 0,
        banned: !!u.banned, banReason: u.banReason || '',
        online: onlineUserIds().indexOf(u.id) >= 0,
        favorites: Array.isArray(u.favorites) ? u.favorites.length : 0
      }),
      logins, friends, chats
    });
    return;
  }

  if (sub === 'users' && parts[3] === 'ban' && method === 'POST') {
    if (!can(admin, 'users.ban')) return fail(res, 403, '你的角色没有封禁权限');
    const u = findUser(parts[2]);
    if (!u) return fail(res, 404, '用户不存在');
    const body = await readBody(req);
    setUserBanned(u, body.banned, body.reason, admin.username);
    audit(req, admin, u.banned ? '封禁账号' : '解封账号', u.username,
      u.banReason || ('踢掉 ' + '所有设备的登录态'));
    ok(res, { banned: !!u.banned, banReason: u.banReason || '', kicked: !!u.banned });
    return;
  }

  if (sub === 'users' && parts[3] === 'reset' && method === 'POST') {
    if (!can(admin, 'users.reset')) return fail(res, 403, '你的角色没有重置密码权限');
    const u = findUser(parts[2]);
    if (!u) return fail(res, 404, '用户不存在');
    const body = await readBody(req);
    const pwd = String(body.password || '').trim();
    if (pwd.length < 6) return fail(res, 422, '新密码至少 6 位');
    u.salt = crypto.randomBytes(16).toString('hex');
    u.passwordHash = hashPassword(pwd, u.salt);
    u.tokenVersion = (u.tokenVersion || 0) + 1;      // 旧登录立刻失效
    saveUsers();
    audit(req, admin, '重置密码', u.username, '');
    ok(res, { reset: true });
    return;
  }

  /* ---------------- 消息 & 会话检索 ---------------- */
  if (sub === 'messages' && method === 'GET') {
    if (!can(admin, 'messages')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const q = str(query.get('q'), 40);
    const kind = str(query.get('kind'), 20);
    const userQ = str(query.get('user'), 40).toLowerCase();
    const from = Number(query.get('from')) || 0;
    const to = Number(query.get('to')) || 0;
    const limit = Math.min(200, Math.max(1, Number(query.get('limit')) || 50));
    const out = [];
    db.chats.forEach((c) => {
      const msgs = loadMessages(c.id);
      for (let i = msgs.length - 1; i >= 0 && out.length < limit; i -= 1) {
        const m = msgs[i];
        if (kind && m.kind !== kind) continue;
        const ts = new Date(m.createdAt).getTime();
        if (from && ts < from) continue;
        if (to && ts > to) continue;
        const sender = findUser(m.senderId);
        if (userQ) {
          const hay = ((sender && (sender.nickname + ' ' + sender.username)) || '') + ' ' + c.id;
          if (hay.toLowerCase().indexOf(userQ) < 0) continue;
        }
        if (q && String(m.content || '').indexOf(q) < 0) continue;
        out.push({
          id: m.id, chatId: c.id, chatTitle: chatSummary(c, m.senderId).title,
          senderId: m.senderId, senderName: sender ? (sender.nickname || sender.username) : '未知',
          kind: m.kind, content: String(m.content || '').slice(0, 500),
          createdAt: m.createdAt, recalled: !!m.recalled, seq: m.seq
        });
      }
    });
    audit(req, admin, '检索消息', q || kind || userQ || '(全部)', '返回 ' + out.length + ' 条');
    ok(res, { messages: out.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt))) });
    return;
  }

  if (sub === 'messages' && parts[3] === 'recall' && method === 'POST') {
    if (!can(admin, 'messages.write')) return fail(res, 403, '你的角色没有强制撤回权限');
    const body = await readBody(req);
    const chatId = str(body.chatId, 60);
    const chat = db.chats.find((c) => c.id === chatId);
    if (!chat) return fail(res, 404, '会话不存在');
    const messages = loadMessages(chat.id);
    const msg = messages.find((m) => m.id === parts[2]);
    if (!msg) return fail(res, 404, '消息不存在');
    msg.recalled = true;
    try {
      saveMessagesFile(chat.id, messages);
    } catch (err) { return fail(res, 500, '写入失败'); }
    sendToChat(chat, { type: 'recall', chatId: chat.id, messageId: msg.id });
    audit(req, admin, '强制撤回消息', parts[2], '会话 ' + chatId);
    ok(res, { message: msg });
    return;
  }

  if (sub === 'chats' && parts[3] === 'clear' && method === 'POST') {
    if (!can(admin, 'messages.write')) return fail(res, 403, '你的角色没有清空会话权限');
    const chat = db.chats.find((c) => c.id === parts[2]);
    if (!chat) return fail(res, 404, '会话不存在');
    const file = path.join(DATA_DIR, 'messages', chat.id + '.jsonl');
    try { fs.writeFileSync(file, ''); } catch (err) { /* 忽略 */ }
    messageCache.delete(chat.id);
    audit(req, admin, '清空会话', chat.id, '');
    ok(res, { cleared: true });
    return;
  }

  /* 后台：以某个用户的名义建一个群（联调 / 测试用，不受「只能是好友」限制）
     POST /api/ops/group/create { username, name, members: [用户名...] } */
  if (sub === 'group' && parts[2] === 'create' && method === 'POST') {
    if (admin.role !== 'super') return fail(res, 403, '只有超级管理员能建群');
    const body = await readBody(req);
    const owner = findUserByName(str(body.username, 24));
    if (!owner) return fail(res, 404, '没有这个用户');
    const name = str(body.name, 30) || '群聊测试';
    const members = [owner.id];
    (Array.isArray(body.members) ? body.members : []).forEach((x) => {
      const t = findUserByName(str(x, 24));
      if (t && members.indexOf(t.id) < 0) members.push(t.id);
    });
    if (members.length < 2) return fail(res, 422, '至少再加一个人');
    const chat = {
      id: uid('c'), type: 'group', name: name, avatar: '',
      memberIds: members, ownerId: owner.id, seq: 0, createdAt: now()
    };
    db.chats.push(chat);
    buildGroupAvatar(chat);            // 九宫格群头像
    chat.seq = 1;
    const others = members.slice(1).map((id) => (findUser(id) || {}).nickname || '').filter(Boolean);
    const sysMsg = {
      id: uid('m'), chatId: chat.id, seq: 1, senderId: 'system', kind: 'system',
      content: '你邀请 ' + others.join('、') + ' 加入了群聊',
      createdAt: now(), recalled: false
    };
    appendMessage(chat.id, sysMsg);
    saveChats();
    members.forEach((id) => {
      sendTo(id, { type: 'chat', action: 'created', chat: chatSummary(chat, id) });
      sendTo(id, { type: 'message', message: sysMsg, chat: chatSummary(chat, id), clientId: null });
    });
    audit(req, admin, '后台建群', chat.id, name + ' · ' + members.length + ' 人');
    ok(res, {
      chat: { id: chat.id, name: chat.name, avatar: chat.avatar, memberCount: members.length }
    });
    return;
  }

  /* 群组管理：后台解散一个群（对应 PC 后台清单里的「群组管理 / 群组设置」） */
  if (sub === 'groups' && method === 'GET') {
    const page = Math.max(1, Number(query.get('page')) || 1);
    const pageSize = Math.min(50, Number(query.get('pageSize')) || 20);
    const kw = str(query.get('q'), 30).toLowerCase();
    let list = db.chats.filter((c) => c.type === 'group');
    if (kw) list = list.filter((c) => String(c.name || '').toLowerCase().indexOf(kw) >= 0);
    list = list.slice().sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    ok(res, {
      total: list.length, page: page, pageSize: pageSize,
      groups: list.slice((page - 1) * pageSize, page * pageSize).map((c) => {
        const messages = loadMessages(c.id);
        const last = messages.length ? messages[messages.length - 1] : null;
        const pv = lastPreviewMessage(messages);
        return {
          id: c.id, name: c.name || '', avatar: c.avatar || '',
          owner: (findUser(c.ownerId) || {}).nickname || '',
          memberCount: c.memberIds.length,
          members: c.memberIds.slice(0, 12).map((id) => publicUser(findUser(id))).filter(Boolean),
          messageCount: messages.length,
          lastPreview: pv ? previewTextOf(pv) : '',
          createdAt: c.createdAt,
          muteAll: !!c.muteAll
        };
      })
    });
    return;
  }

  if (sub === 'groups' && parts[2] === 'dismiss' && method === 'POST') {
    if (admin.role !== 'super') return fail(res, 403, '只有超级管理员能解散群聊');
    const chat = db.chats.find((c) => c.id === parts[1] && c.type === 'group');
    if (!chat) return fail(res, 404, '群不存在');
    const members = chat.memberIds.slice();
    const sys = pushSystemMessage(chat, '管理员解散了该群聊');
    members.forEach((id) => sendTo(id, { type: 'message', message: sys, chat: chatSummary(chat, id), clientId: null }));
    chat.memberIds = [];
    chat.dismissed = true;
    saveChats();
    members.forEach((id) => sendTo(id, { type: 'chat', action: 'removed', chatId: chat.id }));
    audit(req, admin, '后台解散群聊', chat.id, chat.name + ' · 原 ' + members.length + ' 人');
    ok(res, { dismissed: true });
    return;
  }

  /* ---------------- 用户反馈（App「设置 → 意见反馈」提交的那些） ---------------- */
  if (sub === 'feedback' && method === 'GET') {
    const rows = [];
    try {
      const raw = fs.readFileSync(path.join(DATA_DIR, 'feedback.jsonl'), 'utf8');
      raw.split('\n').forEach((line) => {
        const t = line.trim();
        if (!t) return;
        try { rows.push(JSON.parse(t)); } catch (err) { /* 坏行跳过 */ }
      });
    } catch (err) { /* 还没人反馈过 */ }
    const limit = Math.min(500, Math.max(1, Number(query.get('limit')) || 200));
    ok(res, { items: rows.slice(-limit).reverse(), total: rows.length });
    return;
  }

  /* 后台回复一条反馈：写进那行（状态变已回复）+ 给用户推一条实时事件，
     用户在「我的反馈」里就能看到官方回复（和微信一样）。 */
  if (sub === 'feedback' && parts[2] === 'reply' && method === 'POST') {
    if (!can(admin, 'users') && !can(admin, 'support')) return fail(res, 403, '你的角色没有回复反馈的权限');
    const body = await readBody(req);
    const id = str(body.id, 40);
    const reply = String(body.reply || '').slice(0, 1000);
    if (!id || !reply) return fail(res, 422, '要回的内容不能为空');
    const rows = readFeedbackRows();
    const hit = rows.find((r) => r && r.id === id);
    if (!hit) return fail(res, 404, '这条反馈不存在');
    hit.reply = reply;
    hit.status = 'replied';
    hit.repliedAt = now();
    hit.repliedBy = admin.username || '';
    if (!writeFeedbackRows(rows)) return fail(res, 500, '写入失败');
    try {
      sendTo(hit.userId, {
        type: 'feedback', id: hit.id, reply: reply, at: hit.repliedAt
      });
    } catch (err) { }
    audit(req, admin, '回复意见反馈', hit.username || hit.userId, reply.slice(0, 60));
    ok(res, { replied: true, id: id });
    return;
  }

  /* 一次性修复：早期版本会把 video / livephoto 这类消息降级成 text，
     气泡里就把那段 JSON 原样显示出来（用户说的"视频乱码"）。
     这里按很严格的条件把它们改回正确的 kind —— 只改 kind，不动内容。
     识别规则（和 App 发送时的 JSON 一一对应）：
       video     ：{"url": "….mp4", "seconds": n, "cover": "…"}
       livephoto ：{"image": "…", "video": "….mov"} */
  if (sub === 'fix-media-kinds' && method === 'POST') {
    if (admin.role !== 'super') return fail(res, 403, '只有超级管理员能跑这个修复');
    let scanned = 0, fixedVideo = 0, fixedLive = 0;
    db.chats.forEach((c) => {
      const list = loadMessages(c.id);
      let changed = false;
      list.forEach((m) => {
        scanned += 1;
        if (!m || m.recalled) return;
        if (String(m.kind || '') !== 'text') return;
        const t = String(m.content || '').trim();
        if (!t.startsWith('{') || t.length > 2000) return;
        let o = null;
        try { o = JSON.parse(t); } catch (err) { return; }
        if (!o || typeof o !== 'object') return;
        const v1 = String(o.url || '');
        const v2 = String(o.video || '');
        const isVideoFile = (s) => /\.(mp4|mov|m4v|avi|mkv|webm|3gp|flv|wmv)(\?|$)/i.test(s);
        if (o.image && v2 && isVideoFile(v2)) {
          m.kind = 'livephoto'; changed = true; fixedLive += 1;
        } else if (v1 && isVideoFile(v1)) {
          m.kind = 'video'; changed = true; fixedVideo += 1;
        }
      });
      if (changed) {
        try { saveMessagesFile(c.id, list); } catch (err) { }
      }
    });
    audit(req, admin, '修复媒体消息类型', '-', '扫 ' + scanned + ' 条，video ' + fixedVideo + ' / 实况 ' + fixedLive);
    ok(res, { scanned: scanned, video: fixedVideo, livephoto: fixedLive });
    return;
  }

  /* ---------------- 好友关系 ---------------- */
  if (sub === 'friendships' && method === 'GET') {
    if (!can(admin, 'friends')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const status = str(query.get('status'), 20);
    let list = db.friendships.slice();
    if (status) list = list.filter((f) => f.status === status);
    list = list.slice(-300).reverse();
    ok(res, {
      friendships: list.map((f) => {
        const a = findUser(f.fromId), b = findUser(f.toId);
        return {
          id: f.id, status: f.status, createdAt: f.createdAt,
          from: a ? { id: a.id, username: a.username, nickname: a.nickname, banned: !!a.banned } : null,
          to: b ? { id: b.id, username: b.username, nickname: b.nickname, banned: !!b.banned } : null
        };
      })
    });
    return;
  }

  if (sub === 'friendships' && parts[3] === 'remove' && method === 'POST') {
    if (!can(admin, 'friends.write')) return fail(res, 403, '你的角色没有解除好友权限');
    const f = db.friendships.find((x) => x.id === parts[2]);
    if (!f) return fail(res, 404, '这条好友关系不存在');
    db.friendships = db.friendships.filter((x) => x.id !== f.id);
    saveFriendships();
    audit(req, admin, '解除好友关系', f.id, f.fromId + ' ↔ ' + f.toId);
    ok(res, { removed: true });
    return;
  }

  /* ---------------- 风控 / 敏感词 ---------------- */
  if (sub === 'sensitive' && method === 'GET') {
    if (!can(admin, 'risk')) return fail(res, 403, '你的角色没有查看风控的权限');
    ok(res, { words: opsStore.sensitive, violations: opsStore.violations.slice(0, 100) });
    return;
  }

  if (sub === 'sensitive' && method === 'POST') {
    if (!can(admin, 'risk.write')) return fail(res, 403, '你的角色没有改敏感词的权限');
    const body = await readBody(req);
    const add = str(body.add, 40);
    const del = str(body.remove, 40);
    if (add && opsStore.sensitive.indexOf(add) < 0) opsStore.sensitive.push(add);
    if (del) opsStore.sensitive = opsStore.sensitive.filter((w) => w !== del);
    saveSensitive();
    audit(req, admin, add ? '新增敏感词' : '删除敏感词', add || del, '');
    ok(res, { words: opsStore.sensitive });
    return;
  }

  if (sub === 'violations' && parts[3] === 'handle' && method === 'POST') {
    if (!can(admin, 'risk.write')) return fail(res, 403, '没有权限');
    const v = opsStore.violations.find((x) => x.id === parts[2]);
    if (!v) return fail(res, 404, '这条告警不存在');
    v.handled = true;
    v.handledBy = admin.username;
    v.handledAt = now();
    saveViolations();
    audit(req, admin, '处理违规告警', v.id, v.word);
    ok(res, { handled: true });
    return;
  }

  /* ---------------- 举报 ---------------- */
  if (sub === 'reports' && method === 'GET') {
    if (!can(admin, 'reports')) return fail(res, 403, '你的角色没有处理举报的权限');
    ok(res, { reports: opsStore.reports.slice(0, 200) });
    return;
  }

  if (sub === 'reports' && parts[3] === 'handle' && method === 'POST') {
    if (!can(admin, 'reports')) return fail(res, 403, '没有权限');
    const r = opsStore.reports.find((x) => x.id === parts[2]);
    if (!r) return fail(res, 404, '举报不存在');
    const body = await readBody(req);
    r.status = body.ban ? 'banned' : 'done';
    r.note = str(body.note, 200);
    r.handledBy = admin.username;
    r.handledAt = now();
    if (body.ban) {
      const u = findUser(r.targetUserId);
      if (u) setUserBanned(u, true, '举报核实：' + (r.reason || ''), admin.username);
    }
    saveReports();
    audit(req, admin, body.ban ? '举报处理-封号' : '举报处理', r.id, r.reason || '');
    ok(res, { handled: true });
    return;
  }

  /* ---------------- 朋友圈 ---------------- */
  if (sub === 'moments' && method === 'GET') {
    if (!can(admin, 'moments')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const q = str(query.get('q'), 40);
    let list = db.moments.slice();
    if (q) list = list.filter((m) => String(m.content || '').indexOf(q) >= 0);
    ok(res, {
      moments: list.slice(0, 100).map((m) => {
        const a = findUser(m.authorId);
        return {
          id: m.id, content: m.content || '', images: m.images || [], createdAt: m.createdAt,
          author: a ? { id: a.id, username: a.username, nickname: a.nickname } : null,
          likes: (m.likes || []).length, comments: (m.comments || []).length
        };
      })
    });
    return;
  }

  if (sub === 'moments' && parts.length === 3 && method === 'DELETE') {
    if (!can(admin, 'moments.write')) return fail(res, 403, '你的角色没有删动态权限');
    const idx = db.moments.findIndex((m) => m.id === parts[2]);
    if (idx === -1) return fail(res, 404, '动态不存在');
    const [removed] = db.moments.splice(idx, 1);
    saveMoments();
    audit(req, admin, '删除朋友圈动态', removed.id, String(removed.content || '').slice(0, 60));
    ok(res, { deleted: true });
    return;
  }

  /* ---------------- 支付风控 ---------------- */
  if (sub === 'payments' && method === 'GET' && parts.length === 2) {
    if (!can(admin, 'payments')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const q = str(query.get('q'), 40).toLowerCase();
    const status = str(query.get('status'), 20);
    const from = Number(query.get('from')) || 0;
    const to = Number(query.get('to')) || 0;
    const min = Number(query.get('min')) || 0;
    const max = Number(query.get('max')) || 0;
    let list = db.transfers.slice();
    if (status) list = list.filter((t) => t.status === status);
    if (from) list = list.filter((t) => new Date(t.createdAt).getTime() >= from);
    if (to) list = list.filter((t) => new Date(t.createdAt).getTime() <= to);
    if (min) list = list.filter((t) => Number(t.amount) >= min);
    if (max) list = list.filter((t) => Number(t.amount) <= max);
    if (q) {
      list = list.filter((t) => {
        const a = findUser(t.fromId), b = findUser(t.toId);
        const hay = [a && a.username, a && a.nickname, b && b.username, b && b.nickname, t.note, t.id]
          .join(' ').toLowerCase();
        return hay.indexOf(q) >= 0;
      });
    }
    const allToday = db.transfers.filter((t) => new Date(t.createdAt).getTime() >= localDayStart());
    ok(res, {
      transfers: list.slice(0, 300).map((t) => {
        const from = findUser(t.fromId), to = findUser(t.toId);
        return {
          id: t.id, amount: t.amount, note: t.note || '', status: t.status, method: t.method,
          createdAt: t.createdAt, receivedAt: t.receivedAt || '', refundedAt: t.refundedAt || '',
          from: from ? { id: from.id, username: from.username, nickname: from.nickname, banned: !!from.banned } : null,
          to: to ? { id: to.id, username: to.username, nickname: to.nickname, banned: !!to.banned } : null
        };
      }),
      total: db.transfers.length,
      filtered: list.length,
      pending: db.transfers.filter((t) => t.status === 'pending').length,
      volume: Math.round(db.transfers.reduce((a, t) => a + (Number(t.amount) || 0), 0) * 100) / 100,
      today: allToday.length,
      todayVolume: Math.round(allToday.reduce((a, t) => a + (Number(t.amount) || 0), 0) * 100) / 100
    });
    return;
  }

  /* 某一笔的详情：完整流水 + 发起设备 IP + 相关审计 */
  if (sub === 'payments' && parts.length === 3 && method === 'GET') {
    if (!can(admin, 'payments')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const t = db.transfers.find((x) => x.id === parts[2]);
    if (!t) return fail(res, 404, '这笔转账不存在');
    audit(req, admin, '查看交易详情', t.id, '金额 ' + t.amount);
    const payer = findUser(t.fromId), payee = findUser(t.toId);
    const logins = db.security.logins.filter((l) => l.userId === t.fromId).slice(0, 5);
    const related = readAudit(400).filter((a) => String(a.target).indexOf(t.id) >= 0
      || String(a.detail).indexOf(t.id) >= 0
      || (a.action.indexOf('转账') >= 0 && String(a.target).indexOf(t.id) >= 0));
    const chat = db.chats.find((c) => c.id === t.chatId);
    ok(res, {
      transfer: {
        id: t.id, amount: t.amount, note: t.note || '', status: t.status, method: t.method,
        createdAt: t.createdAt, expiresAt: t.expiresAt, receivedAt: t.receivedAt || '',
        refundedAt: t.refundedAt || '', chatId: t.chatId,
        chatTitle: chat ? chatSummary(chat, t.fromId).title : '',
        messageId: t.messageId || ''
      },
      payer: payer ? Object.assign(publicUser(payer), {
        phone: payer.phone || '', banned: !!payer.banned, balance: Number(payer.balance) || 0
      }) : null,
      payee: payee ? Object.assign(publicUser(payee), {
        phone: payee.phone || '', banned: !!payee.banned, balance: Number(payee.balance) || 0
      }) : null,
      logins,
      related
    });
    return;
  }

  /* 撤销/退回一笔待收款的转账（只有超级管理员） */
  if (sub === 'payments' && parts[3] === 'revoke' && method === 'POST') {
    if (!can(admin, 'payments.write')) return fail(res, 403, '你的角色没有查看这一项的权限');
    if (admin.role !== 'super') return fail(res, 403, '只有超级管理员能撤销交易');
    const t = db.transfers.find((x) => x.id === parts[2]);
    if (!t) return fail(res, 404, '这笔转账不存在');
    if (t.status !== 'pending') return fail(res, 422, '只有「待收款」的交易能撤销');
    const body = await readBody(req);
    const payer = findUser(t.fromId);
    t.status = 'refunded';
    t.refundedAt = now();
    if (payer) {
      payer.balance = Math.round(((Number(payer.balance) || 0) + Number(t.amount)) * 100) / 100;
      saveUsers();
      sendTo(payer.id, { type: 'balance', balance: payer.balance });
    }
    saveTransfers();
    broadcastTransfer(t, 'refunded');
    audit(req, admin, '撤销交易', t.id, '退回 ¥' + t.amount + ' 给 ' + (payer ? payer.username : t.fromId)
      + '（' + str(body.reason, 60) + '）');
    ok(res, { revoked: true });
    return;
  }

  /* 冻结 / 解冻账号（只有超级管理员） */
  if (sub === 'payments' && parts[2] === 'freeze' && method === 'POST') {
    if (!can(admin, 'payments.write')) return fail(res, 403, '你的角色没有查看这一项的权限');
    if (admin.role !== 'super') return fail(res, 403, '只有超级管理员能冻结账号');
    const body = await readBody(req);
    const u = findUser(str(body.userId, 40));
    if (!u) return fail(res, 404, '用户不存在');
    setUserBanned(u, body.frozen, str(body.reason, 100) || '支付风控冻结', admin.username);
    audit(req, admin, u.banned ? '冻结账号（支付风控）' : '解冻账号（支付风控）', u.username, u.banReason);
    ok(res, { banned: !!u.banned });
    return;
  }

  /* ---------------- 运维 ---------------- */
  if (sub === 'system' && method === 'GET') {
    if (!can(admin, 'system')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const mem = process.memoryUsage();
    let dbBytes = 0;
    try {
      fs.readdirSync(DATA_DIR).forEach((f) => {
        try { dbBytes += fs.statSync(path.join(DATA_DIR, f)).size; } catch (err) { /* 忽略 */ }
      });
    } catch (err) { /* 忽略 */ }
    ok(res, {
      system: {
        uptime: Math.round(process.uptime()),
        node: process.version,
        platform: process.platform,
        memoryMB: Math.round(mem.rss / 1024 / 1024),
        heapMB: Math.round(mem.heapUsed / 1024 / 1024),
        dataDir: DATA_DIR,
        dataMB: Math.round(dbBytes / 1024 / 1024 * 10) / 10,
        port: PORT,
        httpsPort: HTTPS_PORT
      },
      announce: db.branding && db.branding.announce ? db.branding.announce : ''
    });
    return;
  }

  if (sub === 'system' && parts[2] === 'announce' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有发公告权限');
    const body = await readBody(req);
    const text = str(body.text, 200);
    db.branding.announce = text;
    db.branding.updatedAt = now();
    saveBranding();
    db.users.forEach((u) => sendTo(u.id, { type: 'announce', text }));
    audit(req, admin, '发布系统公告', '', text);
    ok(res, { announce: text });
    return;
  }

  /* ---------------- 审计日志 ---------------- */
  if (sub === 'audit' && method === 'GET') {
    if (!can(admin, 'audit')) return fail(res, 403, '你的角色没有查看这一项的权限');
    const r = readAuditQuery({
      limit: Number(query.get('limit')) || 200,
      from: Number(query.get('from')) || 0,
      to: Number(query.get('to')) || 0,
      q: query.get('q') || ''
    });
    ok(res, { audit: r.rows, total: r.total, days: r.days, truncated: r.truncated });
    return;
  }

  /* ---------------- 发现页（后台自由增删改）---------------- */
  if (sub === 'discover' && method === 'GET') {
    ok(res, {
      items: db.discover || [],
      defaults: DEFAULT_DISCOVER,
      actions: DISCOVER_ACTIONS
    });
    return;
  }

  if (sub === 'discover' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改发现页');
    const body = await readBody(req);
    const items = normalizeDiscover(body.items);
    db.discover = items;
    saveDiscover();
    audit(req, admin, 'discover.save', '发现页', items.length + ' 行');
    // 让在线的客户端知道配置变了（App 收到会重拉一份界面配置）
    sendToAll({ type: 'ui' });
   ok(res, { items: db.discover });
   return;
 }

  /* ---------------- 视频号（后台管控：内容 + 样式 + 开关）---------------- */
  if (sub === 'feed' && method === 'GET') {
    const f = readJson(path.join(DATA_DIR, 'feed.json'), {});
    ok(res, {
      items: f.items || [],
      posts: f.posts || [],
      style: Object.assign({}, FEED_STYLE_DEFAULT, f.style || {}),
      flags: Object.assign({}, FEED_FLAGS_DEFAULT, f.flags || {}),
      defaults: { style: FEED_STYLE_DEFAULT, flags: FEED_FLAGS_DEFAULT }
    });
    return;
  }

  if (sub === 'feed' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改视频号');
    const body = await readBody(req);
    const file = path.join(DATA_DIR, 'feed.json');
    const f = readJson(file, { items: [], posts: [] });
    if (Array.isArray(body.items)) {
      const oldItems = Array.isArray(f.items) ? f.items : [];
      f.items = body.items.map((x, i) => {
        const id = str(x.id, 40) || ('v' + (i + 1));
        const prev = oldItems.find((y) => y && y.id === id);
        return {
          id,
          video: str(x.video, 300),
          cover: str(x.cover, 300),
          desc: str(x.desc, 200),
          music: str(x.music, 80),
          tag: str(x.tag, 20),
          author: str(x.author, 40),
          /* 内置条目的作者头像：不带上它，客户端只能显示名字首字 */
          authorAvatar: str(x.authorAvatar, 300),
          /* 短剧用：集数标签 / 总集数 / 剧集 id / 剧名（客户端左上角显示集数 + 选集） */
          ep: str(x.ep, 20),
          epTotal: Number(x.epTotal) || 0,
          series: str(x.series, 60),
          seriesName: str(x.seriesName, 60),
          baseLikes: Number(x.baseLikes) || 0,
          /* 发布时间：新条目必须带上，否则会被当成"24 小时前"的老视频，推荐排不上去 */
          createdAt: str(x.createdAt, 40) || (prev && prev.createdAt) || now()
        };
      });
    }
    if (body.style && typeof body.style === 'object') f.style = normalizeFeedStyle(body.style);
    if (body.flags && typeof body.flags === 'object') f.flags = normalizeFeedFlags(body.flags);
    writeJson(file, f);
    audit(req, admin, 'feed.save', '视频号', (f.items || []).length + ' 条内置 / ' + (f.posts || []).length + ' 条用户作品');
    sendToAll({ type: 'ui' });
    /* 后台加/换的视频也要做 HLS 分片：没分片的话客户端只能整包拉原片
       （用户反馈的"发了看不到 / 一直转圈"就是这个），这里存完就自动排队 */
    scheduleHlsBuild();
    ok(res, { items: f.items || [], style: f.style, flags: f.flags });
    return;
  }

  /* 后台删掉某个用户发的视频 */
  if (sub === 'feed' && parts[2] === 'posts' && method === 'DELETE') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能删作品');
    const file = path.join(DATA_DIR, 'feed.json');
    const f = readJson(file, { items: [], posts: [] });
    const id = str(parts[3], 40);
    const before = (f.posts || []).length;
    f.posts = (f.posts || []).filter((x) => x.id !== id);
    writeJson(file, f);
    audit(req, admin, 'feed.deletePost', '视频号作品', id);
    ok(res, { removed: before - f.posts.length });
    return;
  }

  /* ---------------- 我页（后台自由增删改）---------------- */
  /* ---------------- 界面文字（ui.json：字号 / 颜色，App 和网页版都读它） ---------------- */
  if (sub === 'uiconfig' && method === 'GET') {
    ok(res, { ui: readJson(path.join(DATA_DIR, 'ui.json'), {}) });
    return;
  }

  /* ---------------- IM 模块（聊天开关 / 各类消息 / 撤回时限 / 群人数…） ---------------- */
  /* ---------------- 短信通道（登录验证码 / 找回密码） ---------------- */
  if (sub === 'sms' && method === 'GET') {
    const c = readSmsCfg();
    ok(res, {
      sms: {
        enabled: c.enabled, provider: c.provider, signName: c.signName, templateCode: c.templateCode,
        accessKeyId: c.accessKeyId,
        hasSecret: !!c.accessKeySecret,          // 密钥不回传，只告诉有没有填过
        twilioSid: c.twilioSid, twilioFrom: c.twilioFrom, hasTwilioToken: !!c.twilioToken,
        customUrl: c.customUrl, customHeader: c.customHeader, note: c.note
      },
      ready: smsReady(c),
      defaults: { provider: DEFAULT_SMS.provider, note: DEFAULT_SMS.note }
    });
    return;
  }

  if (sub === 'sms' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '只有超级管理员能改短信设置');
    const body = await readBody(req);
    const src = body.sms && typeof body.sms === 'object' ? body.sms : (body || {});
    const cur = readSmsCfg();
    const next = Object.assign({}, cur);
    ['enabled', 'provider', 'signName', 'templateCode', 'accessKeyId', 'twilioSid', 'twilioFrom', 'customUrl', 'customHeader']
      .forEach((k) => { if (src[k] !== undefined) next[k] = typeof DEFAULT_SMS[k] === 'boolean' ? !!src[k] : String(src[k] || '').slice(0, 400); });
    ['accessKeySecret', 'twilioToken'].forEach((k) => {
      if (src[k] !== undefined && String(src[k] || '').trim() !== '') next[k] = String(src[k]).trim().slice(0, 200);
    });
    saveSmsCfg(next);
    audit(req, admin, 'sms.save', '短信设置', next.provider + (next.enabled ? ' 已开启' : ' 已关闭'));
    ok(res, { sms: { enabled: next.enabled, provider: next.provider }, ready: smsReady(next) });
    return;
  }

  /* 测试发一条（填完 Key 先试一发，不用等真用户登录） */
  if (sub === 'sms' && parts[2] === 'test' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '只有超级管理员能发测试短信');
    const body = await readBody(req);
    const phone = normalizePhone(body.phone);
    if (!/^1[3-9]\d{9}$/.test(phone)) return fail(res, 422, '手机号格式不对');
    const code = String(Math.floor(100000 + Math.random() * 900000));
    const r = await sendSmsCode(phone, code, readSmsCfg());
    audit(req, admin, 'sms.test', phone, r.ok ? ('验证码 ' + code + ' 已发出') : ('失败：' + r.error));
    if (!r.ok) return fail(res, 502, r.error);
    ok(res, { sent: true, phone });
    return;
  }

  if (sub === 'im' && method === 'GET') {
    ok(res, { im: readIm(), defaults: DEFAULT_IM });
    return;
  }

  /* ---------------- 经营账户查账（后台）：每个人的收款、提现、开票一眼看全 ---------------- */
  if (sub === 'biz' && method === 'GET') {
    if (!can(admin, 'users')) return fail(res, 403, '你的角色没有查账权限');
    const all = readBizAll();
    const day0 = localDayStart();
    const monthPrefix = new Date().toISOString().slice(0, 7);
    const sum = (list) => Math.round(list.reduce((a, r) => a + (Number(r.amount) || 0), 0) * 100) / 100;
    const rows = Object.keys(all.accounts).map((uid) => {
      const acc = all.accounts[uid] || {};
      const records = Array.isArray(acc.records) ? acc.records : [];
      const collects = records.filter((r) => r.kind === 'collect');
      const u = findUser(uid) || {};
      return {
        userId: uid,
        username: u.username || '',
        nickname: u.nickname || '',
        avatar: u.avatar || '',
        enabled: !!acc.enabled,
        arrival: (acc.settings && acc.settings.arrival) || 'balance',
        shopName: (acc.settings && acc.settings.shopName) || '',
        balance: Number(acc.balance) || 0,
        collectAll: sum(collects),
        collectToday: sum(collects.filter((r) => new Date(r.createdAt).getTime() >= day0)),
        collectMonth: sum(collects.filter((r) => String(r.createdAt).slice(0, 7) === monthPrefix)),
        withdraw: sum(records.filter((r) => r.kind === 'withdraw')),
        invoiceDone: sum((acc.invoices || []).filter((i) => i.status === 'done')),
        pendingInvoices: (acc.invoices || []).filter((i) => (i.status || 'pending') === 'pending'),
        invoice: acc.invoice || {},
        lastAt: records.length ? records[0].createdAt : '',
        count: collects.length
      };
    }).filter((r) => r.count || r.balance || r.pendingInvoices.length)
      .sort((a, b) => String(b.lastAt).localeCompare(String(a.lastAt)));
    /* 明细：最近 200 条（可按用户过滤） */
    const wantUser = str(query.get('user'), 40);
    const detail = [];
    Object.keys(all.accounts).forEach((uid) => {
      if (wantUser && uid !== wantUser) return;
      const u = findUser(uid) || {};
      (all.accounts[uid].records || []).forEach((r) => {
        detail.push(Object.assign({}, r, {
          userId: uid, nickname: u.nickname || '', username: u.username || ''
        }));
      });
    });
    detail.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
    ok(res, {
      accounts: rows,
      records: detail.slice(0, 200),
      totals: {
        collect: sum(rows.map((r) => ({ amount: r.collectAll }))),
        today: sum(rows.map((r) => ({ amount: r.collectToday }))),
        month: sum(rows.map((r) => ({ amount: r.collectMonth }))),
        withdraw: sum(rows.map((r) => ({ amount: r.withdraw }))),
        balance: sum(rows.map((r) => ({ amount: r.balance }))),
        accounts: rows.length,
        pendingInvoices: rows.reduce((a, r) => a + r.pendingInvoices.length, 0)
      }
    });
    return;
  }

  /* 后台处理开票申请：开好票标记「已开」/「驳回」 */
  if (sub === 'biz' && parts[2] === 'invoice' && method === 'POST') {
    if (!can(admin, 'users')) return fail(res, 403, '你的角色没有查账权限');
    const body = await readBody(req);
    const userId = str(body.userId, 40);
    const id = str(body.id, 40);
    const action = str(body.action, 12) || 'done';
    const acc = bizOf(userId, false);
    const inv = (acc.invoices || []).find((i) => i.id === id);
    if (!inv) return fail(res, 404, '这张开票申请不在了');
    inv.status = action === 'reject' ? 'rejected' : 'done';
    inv.handledAt = now();
    inv.adminNote = str(body.note, 60);
    saveBizAll();
    audit(req, admin, 'biz.invoice.' + inv.status, userId, '¥' + inv.amount + ' ' + inv.title);
    ok(res, { invoice: inv });
    return;
  }

  /* ---------------- 关键词自动回复（微信后台「自动回复」那套） ---------------- */
  if (sub === 'autoreply' && method === 'GET') {
    if (!can(admin, 'support')) return fail(res, 403, '你的角色没有自动回复权限');
    ok(res, { autoreply: readAutoReply(), defaults: DEFAULT_AUTOREPLY });
    return;
  }
  if (sub === 'autoreply' && method === 'POST') {
    if (!can(admin, 'support.write')) return fail(res, 403, '你的角色不能改自动回复');
    const body = await readBody(req);
    const src = body.autoreply && typeof body.autoreply === 'object' ? body.autoreply : (body || {});
    const next = Object.assign({}, readAutoReply());
    if (src.enabled !== undefined) next.enabled = src.enabled ? 1 : 0;
    if (src.scope !== undefined) next.scope = src.scope === 'all' ? 'all' : 'kefu';
    if (src.fallback !== undefined) next.fallback = str(src.fallback, 500);
    if (Array.isArray(src.rules)) {
      next.rules = src.rules.slice(0, 200).map((r, i) => ({
        id: str(r && r.id, 30) || ('ar' + Date.now().toString().slice(-5) + i),
        keyword: str(r && r.keyword, 60),
        match: (r && r.match === 'exact') ? 'exact' : 'contains',
        reply: str(r && r.reply, 2000),
        enabled: !(r && r.enabled === false)
      })).filter((r) => r.keyword && r.reply);
    }
    const saved = saveAutoReply(next);
    audit(req, admin, 'autoreply.save', '关键词自动回复', saved.rules.length + ' 条规则，' + (saved.enabled ? '已开启' : '未开启'));
    ok(res, { autoreply: saved });
    return;
  }

  /* 后台直接给某个账号设活跃天（想给谁挂个月亮/太阳/皇冠，用这个；
     320 天 = Lv.16 = 1 个太阳，1152 = Lv.32 = 2 个太阳，4352 = Lv.64 = 1 个皇冠） */
  if (sub === 'growth' && parts[2] === 'set' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改成长系统的权限');
    const body = await readBody(req);
    const target = str(body.userId, 40)
      ? findUser(str(body.userId, 40))
      : findUserByName(str(body.username, 40));
    if (!target) return fail(res, 404, '找不到这个账号');
    const days = Math.max(0, Math.min(100000, Number(body.days) || 0));
    const a = activityOf(target.id);
    a.total = Math.round(days * 10) / 10;
    a.updatedAt = now();
    saveActivityNow();
    const snap = growthSnapshot(target.id);
    audit(req, admin, 'growth.set', target.username || target.id, '活跃天=' + a.total + ' 等级=Lv.' + snap.levelShown);
    ok(res, {
      user: { id: target.id, username: target.username || '', nickname: target.nickname || '' },
      growth: snap
    });
    return;
  }

  /* ---------------- 成长系统（QQ 等级那套：活跃天 / 等级 / 显示位置） ---------------- */
  if (sub === 'growth' && method === 'GET') {
    if (!can(admin, 'ops')) return fail(res, 403, '你的角色没有查看成长系统的权限');
    /* 等级对照表：给后台看着改阈值用的（前 20 级 + 几个里程碑） */
    const table = [];
    [1, 2, 3, 4, 5, 8, 10, 12, 16, 20, 24, 32, 40, 48, 56, 64, 80, 96, 128, 144].forEach((L) => {
      table.push({ level: L, days: qqDaysForLevel(L), icons: qqIconsOf(L) });
    });
    ok(res, {
      growth: readGrowthCfg(),
      effective: publicGrowthCfg(),
      table,
      rank: qqRanking(30),
      users: Object.keys(activityMap()).length
    });
    return;
  }
  if (sub === 'growth' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改成长系统的权限');
    const body = await readBody(req);
    const n = (v, lo, hi, def) => {
      const x = Number(v);
      return (isFinite(x) && x >= lo && x <= hi) ? x : def;
    };
    const next = saveGrowthCfg({
      enabled: !!body.enabled,
      fullSeconds: Math.round(n(body.fullSeconds, 60, 43200, DEFAULT_GROWTH.fullSeconds)),
      halfSeconds: Math.round(n(body.halfSeconds, 30, 21600, DEFAULT_GROWTH.halfSeconds)),
      maxPerDay: Math.round(n(body.maxPerDay, 0.5, 10, DEFAULT_GROWTH.maxPerDay) * 10) / 10,
      boost: Math.round(n(body.boost, 1, 5, DEFAULT_GROWTH.boost) * 10) / 10,
      showInContacts: !!body.showInContacts,
      showInChats: !!body.showInChats,
      showInProfile: !!body.showInProfile,
      avatarFrame: !!body.avatarFrame,
      minShowLevel: Math.round(n(body.minShowLevel, 1, 144, DEFAULT_GROWTH.minShowLevel)),
      tip: String(body.tip || DEFAULT_GROWTH.tip).slice(0, 200)
    });
    audit(req, admin, 'growth.save', '成长系统', '开启=' + (next.enabled ? '是' : '否')
      + ' 满2小时=' + next.fullSeconds + 's 加速=' + next.boost);
    sendToAll({ type: 'growth' });          // 在线客户端立刻重拉
    ok(res, { growth: next, effective: publicGrowthCfg() });
    return;
  }

  /* ---------------- 会员：后台配置 / 给谁开会员 / 生成兑换码 / 会员名单 ---------------- */
  if (sub === 'membership' && parts[2] === 'set' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改会员的权限');
    const body = await readBody(req);
    const target = str(body.userId, 40)
      ? findUser(str(body.userId, 40))
      : findUserByName(str(body.username, 40));
    if (!target) return fail(res, 404, '找不到这个账号');
    /* 撤销：到期时间直接拨到现在，徽章/加速就都没了 */
    if (body.cancel) {
      const dbm = readMemberDb();
      const rec = dbm.users[target.id];
      if (rec) {
        rec.expireAt = Date.now() - 1000;
        rec.autoRenew = false;
        rec.updatedAt = now();
        saveMemberDb();
      }
      audit(req, admin, '会员撤销', target.username || target.id, '');
      ok(res, { membership: memberOf(target.id) });
      return;
    }
    const tier = tierOf(str(body.tierId, 20));
    if (!tier) return fail(res, 404, '没有这个档位');
    const days = Math.max(1, Math.min(3650, Math.floor(Number(body.days) || 30)));
    const me = setMember(target.id, tier.id, days, 'ops', 0, 0);
    audit(req, admin, '会员设置', target.username || target.id, tier.name + ' +' + days + ' 天');
    ok(res, {
      user: { id: target.id, username: target.username || '', nickname: target.nickname || '' },
      membership: me
    });
    return;
  }

  /* 生成兑换码：一张只能用一次，用户端「会员中心 → 兑换码」里用 */
  if (sub === 'membership' && parts[2] === 'code' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改会员的权限');
    const body = await readBody(req);
    const tier = tierOf(str(body.tierId, 20));
    if (!tier) return fail(res, 404, '没有这个档位');
    const days = Math.max(1, Math.min(3650, Math.floor(Number(body.days) || 30)));
    const count = Math.max(1, Math.min(200, Math.floor(Number(body.count) || 1)));
    const dbm = readMemberDb();
    const made = [];
    for (let i = 0; i < count; i += 1) {
      let code = '';
      do {
        code = crypto.randomBytes(4).toString('hex').toUpperCase();
      } while (dbm.codes.some((c) => c.code === code));
      dbm.codes.push({ code, tierId: tier.id, days, createdAt: now(), usedBy: '', usedAt: '' });
      made.push(code);
    }
    saveMemberDb();
    audit(req, admin, '生成会员兑换码', tier.name, made.length + ' 张 / ' + days + ' 天');
    ok(res, { codes: made, tier: tier.name, days });
    return;
  }

  /* ---------------- 音乐（App「听一听」的曲库） ---------------- */
  /* ---------------- 小程序 / 小游戏（后台可以加，App 不用出包） ---------------- */
  if (sub === 'miniapps' && method === 'GET') {
    if (!can(admin, 'ops')) return fail(res, 403, '你的角色没有查看内容的权限');
    ok(res, { items: (readMiniApps().items || []) });
    return;
  }
  if (sub === 'miniapps' && parts[2] === 'add' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改内容的权限');
    const mb = await readBody(req);
    const name = str(mb.name, 20).replace(/\s+/g, ' ').trim();
    const url = str(mb.url, 400).trim();
    if (!name) return fail(res, 422, '名字不能为空');
    if (!/^(\/|https?:\/\/)/.test(url)) return fail(res, 422, '入口地址要写 / 开头（服务器上的文件）或 http(s):// 开头');
    const cfg = readMiniApps();
    const item = {
      id: 'ma' + Date.now().toString(36),
      name: name,
      desc: str(mb.desc, 40).replace(/\s+/g, ' ').trim(),
      icon: str(mb.icon, 8) || '🧩',
      kind: (str(mb.kind, 8) === 'game') ? 'game' : 'mini',
      url: url,
      cover: /^(\/|https?:\/\/)/.test(str(mb.cover, 400).trim()) ? str(mb.cover, 400).trim() : '',
      group: str(mb.group, 16).replace(/\s+/g, ' ').trim(),
      action: str(mb.action, 6).replace(/\s+/g, ' ').trim() || '立即玩',
      enabled: true
    };
    cfg.items.push(item);
    saveMiniApps(cfg);
    audit(req, admin, 'miniapp.add', '小程序', name + ' → ' + url);
    ok(res, { item: item, items: cfg.items.length });
    return;
  }
  if (sub === 'miniapps' && parts[2] === 'update' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改内容的权限');
    const mb = await readBody(req);
    const id = str(mb.id, 40);
    const cfg = readMiniApps();
    const it = cfg.items.filter((x) => (x.id || '') === id)[0];
    if (!it) return fail(res, 404, '找不到这个小程序');
    const name = str(mb.name, 20).replace(/\s+/g, ' ').trim();
    const url = str(mb.url, 400).trim();
    if (name) it.name = name;
    if (url && /^(\/|https?:\/\/)/.test(url)) it.url = url;
    if (mb.icon !== undefined) it.icon = str(mb.icon, 8);
    if (mb.desc !== undefined) it.desc = str(mb.desc, 40).replace(/\s+/g, ' ').trim();
    if (mb.kind !== undefined) it.kind = (str(mb.kind, 8) === 'game') ? 'game' : 'mini';
    if (mb.cover !== undefined) {
      const cv = str(mb.cover, 400).trim();
      it.cover = /^(\/|https?:\/\/)/.test(cv) ? cv : '';
    }
    if (mb.group !== undefined) it.group = str(mb.group, 16).replace(/\s+/g, ' ').trim();
    if (mb.action !== undefined) it.action = str(mb.action, 6).replace(/\s+/g, ' ').trim() || '立即玩';
    saveMiniApps(cfg);
    audit(req, admin, 'miniapp.update', '小程序', it.name + ' → ' + it.url);
    ok(res, { item: it });
    return;
  }
  if (sub === 'miniapps' && parts[2] === 'remove' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改内容的权限');
    const mb = await readBody(req);
    const id = str(mb.id, 40);
    const cfg = readMiniApps();
    const before = cfg.items.length;
    cfg.items = cfg.items.filter((x) => (x.id || '') !== id);
    saveMiniApps(cfg);
    audit(req, admin, 'miniapp.remove', '小程序', id);
    ok(res, { removed: before - cfg.items.length, items: cfg.items.length });
    return;
  }
  if (sub === 'miniapps' && parts[2] === 'toggle' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改内容的权限');
    const mb = await readBody(req);
    const id = str(mb.id, 40);
    const cfg = readMiniApps();
    const it = cfg.items.filter((x) => (x.id || '') === id)[0];
    if (!it) return fail(res, 404, '找不到这个小程序');
    it.enabled = !(it.enabled !== false);
    saveMiniApps(cfg);
    ok(res, { id: id, enabled: it.enabled !== false });
    return;
  }

  /* 系统通知开关（照微信团队那个号）：后台面板里管控 */
  if (sub === 'sysnotice' && method === 'GET') {
    if (!can(admin, 'ops')) return fail(res, 403, '你的角色没有查看内容的权限');
    ok(res, readSysNoticeCfg());
    return;
  }
  if (sub === 'sysnotice' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改内容的权限');
    const b = await readBody(req);
    const cur = readSysNoticeCfg();
    if (b.enabled !== undefined) cur.enabled = b.enabled ? 1 : 0;
    if (b.types && typeof b.types === 'object') {
      Object.keys(cur.types).forEach((k) => { if (b.types[k] !== undefined) cur.types[k] = b.types[k] ? 1 : 0; });
    }
    if (b.texts && typeof b.texts === 'object') {
      Object.keys(b.texts).forEach((k) => { cur.texts[k] = String(b.texts[k] || '').slice(0, 500); });
    }
    saveSysNoticeCfg(cur);
    audit(req, admin, 'sysnotice.save', '系统通知', JSON.stringify(cur.types));
    ok(res, cur);
    return;
  }

  if (sub === 'music' && method === 'GET') {
    if (!can(admin, 'ops')) return fail(res, 403, '你的角色没有查看内容的权限');
    ok(res, { tracks: readMusicDb().tracks });
    return;
  }
  if (sub === 'music' && parts[2] === 'add' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改内容的权限');
    const mb = await readBody(req);
    const title = str(mb.title, 60).replace(/\s+/g, ' ').trim();
    const url = str(mb.url, 400).trim();
    if (!title) return fail(res, 422, '歌名不能为空');
    if (!/^(\/uploads\/|https?:\/\/)/.test(url)) return fail(res, 422, '音频地址不对（先用上面的「音频文件」传一次）');
    const dbm = readMusicDb();
    const track = {
      id: uid('mus'),
      title: title,
      artist: str(mb.artist, 60).replace(/\s+/g, ' ').trim(),
      cover: /^(\/uploads\/|https?:\/\/)/.test(str(mb.cover, 400).trim()) ? str(mb.cover, 400).trim() : '',
      url: url,
      lyrics: str(mb.lyrics, 20000),
      at: Date.now()
    };
    dbm.tracks.unshift(track);
    saveMusicDb(dbm);
    audit(req, admin, 'music.add', '音乐曲库', title + (track.artist ? ' / ' + track.artist : ''));
    ok(res, { track: track, tracks: dbm.tracks.length });
    return;
  }
  /* 改歌词 / 清空歌词（后台「音乐（听一听）」里每首后面那个按钮） */
  if (sub === 'music' && parts[2] === 'lyrics' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改内容的权限');
    const mb = await readBody(req);
    const id = str(mb.id, 40);
    const dbm = readMusicDb();
    const t = dbm.tracks.filter((x) => (x.id || '') === id)[0];
    if (!t) return fail(res, 404, '找不到这首歌');
    t.lyrics = str(mb.lyrics, 20000);
    saveMusicDb(dbm);
    audit(req, admin, 'music.lyrics', '音乐曲库', t.title + '（' + t.lyrics.length + ' 字）');
    ok(res, { id: id, lyrics: t.lyrics, length: t.lyrics.length });
    return;
  }
  if (sub === 'music' && parts[2] === 'remove' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改内容的权限');
    const mb = await readBody(req);
    const id = str(mb.id, 40);
    const dbm = readMusicDb();
    const before = dbm.tracks.length;
    dbm.tracks = dbm.tracks.filter((t) => (t.id || '') !== id);
    saveMusicDb(dbm);
    audit(req, admin, 'music.remove', '音乐曲库', id);
    ok(res, { removed: before - dbm.tracks.length, tracks: dbm.tracks.length });
    return;
  }

  if (sub === 'membership' && method === 'GET') {
    if (!can(admin, 'ops')) return fail(res, 403, '你的角色没有查看会员的权限');
    const dbm = readMemberDb();
    const rows = Object.keys(dbm.users).map((id) => {
      const u = findUser(id) || {};
      const m = memberOf(id);
      return {
        id,
        username: u.username || '',
        nickname: u.nickname || '',
        avatar: u.avatar || '',
        tier: m.tier || '',
        tierName: m.name || '',
        active: !!m.active,
        expireAt: Number(m.expireAt) || 0,
        daysLeft: Number(m.daysLeft) || 0,
        autoRenew: !!m.autoRenew
      };
    }).sort((a, b) => (b.expireAt || 0) - (a.expireAt || 0));
    ok(res, {
      membership: {
        cfg: memberCfg(),
        defaults: { tiers: MEMBER_TIERS_DEFAULT, benefits: MEMBER_BENEFITS_DEFAULT },
        active: rows.filter((r) => r.active).length,
        total: rows.length,
        users: rows.slice(0, 200),
        codes: dbm.codes.slice(-80).reverse()
      }
    });
    return;
  }

  if (sub === 'membership' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改会员的权限');
    const body = await readBody(req);
    const dbm = readMemberDb();
    const next = Object.assign({}, dbm.cfg);
    if (body.enabled !== undefined) next.enabled = !!body.enabled;
    if (body.title !== undefined) next.title = str(body.title, 20);
    if (body.sub !== undefined) next.sub = str(body.sub, 60);
    if (Array.isArray(body.tiers)) next.tiers = body.tiers.slice(0, 6);
    if (Array.isArray(body.benefits)) next.benefits = body.benefits.slice(0, 12);
    dbm.cfg = next;
    saveMemberDb();
    audit(req, admin, '修改会员配置', '', '档位 ' + memberCfg().tiers.length + ' 个');
    ok(res, { cfg: memberCfg() });
    return;
  }

  /* ---------------- 红包封面：封面库（名字 / 封面图 / 缩略图 / 主题色 / 启用 / 默认） ---------------- */
  if (sub === 'rpcovers' && method === 'GET') {
    if (!can(admin, 'icons')) return fail(res, 403, '只有超级管理员能看红包封面');
    ok(res, { covers: readRpCovers(), defaults: DEFAULT_RP_COVERS });
    return;
  }

  if (sub === 'rpcovers' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改红包封面');
    const body = await readBody(req);
    const src = body.covers && typeof body.covers === 'object' ? body.covers : (body || {});
    const next = {};
    if (Array.isArray(src.covers)) {
      next.covers = src.covers.slice(0, 40).map((c, i) => ({
        id: str(c && c.id, 30) || ('cv' + Date.now().toString().slice(-5) + i),
        name: str(c && c.name, 20) || ('封面 ' + (i + 1)),
        image: str(c && c.image, 300),
        thumb: str(c && (c.thumb || c.image), 300),
        color: /^#[0-9a-fA-F]{6}$/.test(String((c && c.color) || '')) ? String(c.color) : '#B3241C',
        enabled: !(c && c.enabled === false)
      })).filter((c) => c.image);
      if (!next.covers.length) next.covers = DEFAULT_RP_COVERS.covers;
    }
    if (src.defaultId !== undefined) next.defaultId = str(src.defaultId, 30);
    const saved = saveRpCovers(next);
    audit(req, admin, 'rpcovers.save', '红包封面', saved.covers.length + ' 张，默认 ' + saved.defaultId);
    ok(res, { covers: saved });
    return;
  }

  /* ---------------- 客服中心：常见问题 + 在线客服 + 工单 ---------------- */
  if (sub === 'support' && method === 'GET') {
    if (!can(admin, 'support')) return fail(res, 403, '你的角色没有客服中心的权限');
    const cfg = readSupport();
    const online = onlineUserIds();
    const tickets = readSupportTickets(200).map((t) => {
      const u = findUser(t.userId) || {};
      return Object.assign({}, t, {
        nickname: u.nickname || t.nickname || '',
        username: u.username || t.username || '',
        avatar: u.avatar || '',
        online: online.indexOf(t.userId) >= 0
      });
    });
    ok(res, {
      support: cfg,
      defaults: DEFAULT_SUPPORT,
      tickets,
      pending: tickets.filter((t) => (t.status || 'pending') === 'pending').length,
      agent: (function () { const a = supportAgent(); return { id: a.id, nickname: a.nickname, avatar: a.avatar || '' }; })()
    });
    return;
  }

  if (sub === 'support' && parts.length === 2 && method === 'POST') {
    if (!can(admin, 'support.write')) return fail(res, 403, '你的角色不能改客服中心');
    const body = await readBody(req);
    const src = body.support && typeof body.support === 'object' ? body.support : (body || {});
    const next = Object.assign({}, readSupport());
    ['title', 'searchHint', 'phone', 'email', 'workTime', 'greet', 'ticketHint']
      .forEach((k) => { if (src[k] !== undefined) next[k] = String(src[k] || '').slice(0, 300); });
    ['human', 'autoReply', 'ticketOn'].forEach((k) => { if (src[k] !== undefined) next[k] = src[k] ? 1 : 0; });
    if (Array.isArray(src.categories)) {
      next.categories = src.categories.slice(0, 30).map((c, i) => ({
        id: str(c && c.id, 20) || ('sp' + (i + 1)),
        title: str(c && c.title, 30) || '未命名',
        icon: str(c && c.icon, 8) || '',
        items: (c && Array.isArray(c.items) ? c.items : []).slice(0, 80).map((it) => ({
          q: str(it && it.q, 120),
          a: str(it && it.a, 3000)
        })).filter((it) => it.q)
      })).filter((c) => c.items.length);
      if (!next.categories.length) next.categories = DEFAULT_SUPPORT.categories;
    }
    const saved = saveSupport(next);
    audit(req, admin, 'support.save', '客服中心', saved.categories.length + ' 个分类');
    ok(res, { support: saved });
    return;
  }

  /* 工单：回复（同时发进用户和「在线客服」的会话）/ 结单 / 重新打开 */
  if (sub === 'support' && parts[2] === 'ticket' && method === 'POST') {
    if (!can(admin, 'support.write')) return fail(res, 403, '你的角色不能处理工单');
    const body = await readBody(req);
    const id = str(body.id, 40);
    const action = str(body.action, 12) || 'reply';
    const t = readSupportTickets(500).find((x) => x.id === id);
    if (!t) return fail(res, 404, '这张工单不在了');
    const u = findUser(t.userId);
    const reply = str(body.reply, 1000);
    let chatId = '';
    if (action === 'reply' && reply) {
      if (!u) return fail(res, 404, '提工单的用户不在了');
      const chat = supportChatFor(u.id);
      chatId = chat.id;
      const r = deliverMessage(supportAgent(), chat.id, 'text', reply, null);
      if (r && r.error) return fail(res, 422, r.error);
    }
    const patch = {};
    if (reply) patch.reply = reply;
    if (action === 'reply') { patch.status = 'replied'; patch.repliedAt = now(); }
    if (action === 'close') { patch.status = 'done'; patch.doneAt = now(); }
    if (action === 'reopen') { patch.status = 'pending'; patch.doneAt = ''; }
    const savedTicket = updateSupportTicket(id, patch);
    audit(req, admin, 'support.ticket.' + action, t.userId, (reply || '').slice(0, 80));
    ok(res, { ticket: savedTicket, chatId });
    return;
  }


  /* ---------------- 零钱：充值 / 提现（规则 + 记录 + 审核） ---------------- */
  if (sub === 'wallet' && method === 'GET') {
    const rules = readWalletRules();
    const ops = readWalletOps().ops.slice(0, 300).map((o) => {
      const u = findUser(o.userId) || {};
      return Object.assign({}, o, { username: u.username || '', nickname: u.nickname || '' });
    });
    ok(res, { rules, ops, defaults: DEFAULT_WALLET_RULES });
    return;
  }

  if (sub === 'wallet' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '只有超级管理员能改零钱规则');
    const body = await readBody(req);
    const src = body.rules && typeof body.rules === 'object' ? body.rules : (body || {});
    const next = Object.assign({}, readWalletRules());
    ['allowRecharge', 'withdrawReview'].forEach((k) => { if (src[k] !== undefined) next[k] = src[k] ? 1 : 0; });
    ['rechargeMax', 'withdrawMin', 'withdrawMax', 'feeMin'].forEach((k) => {
      if (src[k] !== undefined) { const v = Number(src[k]); if (isFinite(v) && v >= 0) next[k] = v; }
    });
    if (src.feeRate !== undefined) {
      const v = Number(src.feeRate);
      if (isFinite(v) && v >= 0 && v <= 0.1) next.feeRate = v;
    }
    if (src.note !== undefined) next.note = String(src.note || '').slice(0, 200);
    const saved = saveWalletRules(next);
    /* 兼容老开关：security.json 里的 allowRecharge 也一起跟着开/关 */
    try {
      const sp = path.join(DATA_DIR, 'security.json');
      const sec = readJson(sp, {});
      sec.allowRecharge = saved.allowRecharge ? 1 : 0;
      writeJson(sp, sec);
      secCache = { at: 0, cfg: null };
    } catch (e) { }
    audit(req, admin, 'wallet.rules', '零钱规则', JSON.stringify(saved).slice(0, 160));
    ok(res, { rules: saved });
    return;
  }

  /* 提现审核：标记「已到账」或者「退回零钱」 */
  if (sub === 'wallet' && parts[2] === 'op' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '只有超级管理员能处理提现');
    const body = await readBody(req);
    const id = str(body.id, 40);
    const action = str(body.action, 12) || 'done';
    const d = readWalletOps();
    const op = d.ops.find((o) => o.id === id);
    if (!op) return fail(res, 404, '这条记录不在了');
    if (op.kind !== 'withdraw') return fail(res, 422, '只有提现需要处理');
    const u = findUser(op.userId);
    if (action === 'done') {
      op.status = 'done';
      op.doneAt = now();
      saveWalletOps();
      audit(req, admin, 'wallet.withdraw.done', op.userId, '¥' + op.amount);
      ok(res, { op });
      return;
    }
    if (action === 'fail') {
      /* 退回：本金 + 手续费一起还给用户 */
      if (u) {
        u.balance = Math.round(((Number(u.balance) || 0) + Number(op.amount || 0) + Number(op.fee || 0)) * 100) / 100;
        saveUsers();
        sendTo(u.id, { type: 'balance', balance: u.balance });
      }
      op.status = 'failed';
      op.doneAt = now();
      saveWalletOps();
      audit(req, admin, 'wallet.withdraw.fail', op.userId, '退回 ¥' + op.amount);
      ok(res, { op, refunded: true });
      return;
    }
    return fail(res, 422, '不认识的操作');
  }

  /* ---------------- 推送通知（APNs）：密钥配置 + 自检 + 试推一条 ---------------- */
  if (sub === 'push' && method === 'GET') {
    const p = readPush();
    const c = p.config;
    let devices = 0;
    Object.keys(p.tokens).forEach((uid) => { devices += (p.tokens[uid] || []).length; });
    let log = [];
    try {
      log = fs.readFileSync(path.join(DATA_DIR, 'push-log.jsonl'), 'utf8').trim().split('\n')
        .slice(-20).map((l) => { try { return JSON.parse(l); } catch (e) { return null; } }).filter(Boolean).reverse();
    } catch (e) { log = []; }
    ok(res, {
      push: {
        enabled: !!c.enabled, bundleId: c.bundleId, teamId: c.teamId, keyId: c.keyId,
        keyPath: c.keyPath, sandbox: !!c.sandbox,
        hasKeyText: !!c.keyText,
        onMessage: c.onMessage !== false, onFriend: c.onFriend !== false, onCall: c.onCall !== false
      },
      ready: pushReady(),
      devices, users: Object.keys(p.tokens).length,
      settings: p.settings || {},
      log
    });
    return;
  }

  /* 注意：这一条只管 /api/ops/push 本身；/api/ops/push/test 要排在后面单独处理 */
  if (sub === 'push' && method === 'POST' && parts.length === 2) {
    if (!can(admin, 'ops.write')) return fail(res, 403, '只有超级管理员能改推送设置');
    const body = await readBody(req);
    const src = body.push && typeof body.push === 'object' ? body.push : (body || {});
    const p = readPush();
    const c = p.config;
    const STR = ['bundleId', 'teamId', 'keyId', 'keyPath'];
    STR.forEach((k) => { if (src[k] !== undefined) c[k] = String(src[k] || '').trim().slice(0, 200); });
    ['enabled', 'sandbox', 'onMessage', 'onFriend', 'onCall']
      .forEach((k) => { if (src[k] !== undefined) c[k] = !!src[k]; });
    if (src.keyText !== undefined && String(src.keyText).trim() !== '') c.keyText = String(src.keyText).trim().slice(0, 4000);
    savePush();
    jwtCache = { at: 0, token: '', key: '' };        // 换了密钥，JWT 必须重新签
    pushCache = null;
    audit(req, admin, 'push.save', '推送设置', c.enabled ? '已开启' : '已关闭');
    ok(res, { push: { enabled: c.enabled, bundleId: c.bundleId }, ready: pushReady() });
    return;
  }

  /* 试推一条：给自己（管理员账号）或者指定用户名推 */
  if (sub === 'push' && parts[2] === 'test' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '只有超级管理员能试推');
    const body = await readBody(req);
    let target = str(body.username, 24) ? findUserByName(body.username) : null;
    if (!target) {
      /* 没填用户名就挑一个「最近登记过推送」的手机 */
      const keys = Object.keys(readPush().tokens);
      if (keys.length) target = findUser(keys[keys.length - 1]);
    }
    if (!target) return fail(res, 404, '还没有手机登记过推送（先用 App 登录一次，或者填一个用户名）');
    const r = await pushToUser(target.id, {
      kind: 'message', title: 'Luchat 测试推送', body: '看到这条就说明推送通道通了 🎉', chatId: 'test'
    });
    audit(req, admin, 'push.test', target.username || target.id, JSON.stringify(r));
    if (!r.sent) return fail(res, 502, '没发出去：' + r.reason + (pushReady() ? '' : '（密钥还没配好）'));
    ok(res, { sent: true, to: target.username || target.id });
    return;
  }

  if (sub === 'im' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改 IM 模块');
    const body = await readBody(req);
    const patch = body.im && typeof body.im === 'object' ? body.im : (body || {});
    const saved = saveIm(patch);
    audit(req, admin, 'im.save', 'IM 模块', Object.keys(patch).join(','));
    sendToAll({ type: 'ui' });                    // 在线客户端立刻生效
    ok(res, { im: saved });
    return;
  }

  if (sub === 'uiconfig' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改界面文字');
    const body = await readBody(req);
    const patch = body.ui && typeof body.ui === 'object' ? body.ui : {};
    const cur = readJson(path.join(DATA_DIR, 'ui.json'), {});
    const touched = [];
    Object.keys(patch).forEach((k) => {
      if (k.charAt(0) === '_') return;                      // 不动注释
      const v = patch[k];
      if (v === null || v === '') { delete cur[k]; }
      else if (typeof v === 'number' || typeof v === 'string' || typeof v === 'boolean') { cur[k] = v; touched.push(k); }
    });
    writeJson(path.join(DATA_DIR, 'ui.json'), cur);
    audit(req, admin, 'uiconfig.save', '界面文字', touched.join(','));
    sendToAll({ type: 'ui' });                            // 在线客户端立刻重拉一份
    ok(res, { ui: cur });
    return;
  }

  if (sub === 'mepage' && method === 'GET') {
    ok(res, { items: db.mePage || [], defaults: DEFAULT_ME_PAGE, actions: ME_ACTIONS });
    return;
  }

  /* 给用户加/减余额（后台用户详情里用）：走统一入口，记总账、发余额事件 */
  if (sub === 'user-recharge' && method === 'POST') {
    if (!can(admin, 'users.money')) return fail(res, 403, '你的角色没有改余额的权限');
    const body = await readBody(req);
    const uname = str(body.username, 24).toLowerCase();
    const target = findUser(str(body.userId, 40))
      || (uname ? (db.users.find((u) => String(u.username || '').toLowerCase() === uname) || null) : null);
    if (!target) return fail(res, 404, '用户不存在');
    const amount = moneyRound(body.amount);
    if (!isFinite(amount) || amount === 0) return fail(res, 422, '金额不合法');
    const r = applyMoney(target, amount, {
      reason: amount > 0 ? '后台充值' : '后台扣减',
      ref: admin.username,
      allowNegative: amount < 0
    });
    if (r.error) return fail(res, 402, r.error);
    saveUsers();
    sendTo(target.id, { type: 'balance', balance: target.balance });
    audit(req, admin, amount > 0 ? '后台充值' : '后台扣减', target.username, amount.toFixed(2));
    ok(res, { id: target.id, username: target.username, nickname: target.nickname,
              balanceBefore: r.before, delta: amount, balance: Number(target.balance) || 0 });
    return;
  }

  if (sub === 'mepage' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改我页');
    const body = await readBody(req);
    const items = normalizeMePage(body.items);
    db.mePage = items;
    saveMePage();
    audit(req, admin, 'mepage.save', '我页', items.length + ' 行');
    sendToAll({ type: 'ui' });
    ok(res, { items: db.mePage });
    return;
  }


  /* ---------------- 聊天壁纸（默认壁纸 + 6 张基础壁纸，都能换）---------------- */
  if (sub === 'chatbg' && method === 'GET') {
    ok(res, { cfg: db.chatBg || normalizeChatBg(null), defaults: DEFAULT_CHAT_BG });
    return;
  }

  if (sub === 'chatbg' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改聊天壁纸');
    const body = await readBody(req);
    const prevVer = Number((db.chatBg && db.chatBg.version) || 1) || 1;
    const cfg = normalizeChatBg({ default: body.default, presets: body.presets });
    cfg.version = prevVer + 1;
    db.chatBg = cfg;
    saveChatBg();
    /* 默认壁纸同步写进 branding.chatBackground，App 拿这个字段当默认背景 */
    if (!db.branding || typeof db.branding !== 'object') db.branding = {};
    db.branding.chatBackground = cfg.default || '';
    saveBranding();
    audit(req, admin, 'chatbg.save', '聊天壁纸',
          cfg.presets.length + ' 张' + (cfg.default ? ' + 默认' : ''));
    sendToAll({ type: 'ui' });
    ok(res, { cfg: db.chatBg });
    return;
  }

  /* ---------------- 服务页（绿卡 + 分类 + 格子，全都能改）---------------- */
  if (sub === 'service' && method === 'GET') {
    ok(res, {
      service: db.service || normalizeService(null),
      defaults: DEFAULT_SERVICE,
      actions: SERVICE_ACTIONS
    });
    return;
  }

  if (sub === 'service' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改服务页');
    const body = await readBody(req);
    const cfg = normalizeService(body.service || body);
    db.service = cfg;
    saveService();
    const cells = (cfg.groups || []).reduce((n, g) => n + (g.items || []).length, 0);
    audit(req, admin, 'service.save', '服务页', (cfg.groups || []).length + ' 组 / ' + cells + ' 格');
    sendToAll({ type: 'ui' });
    ok(res, { service: db.service });
    return;
  }

  /* ---------------- 钱包页（两张白卡 + 底部链接，全都能改）---------------- */
  if (sub === 'wallet' && method === 'GET') {
    ok(res, {
      wallet: db.wallet || normalizeWallet(null),
      defaults: DEFAULT_WALLET,
      actions: WALLET_ACTIONS
    });
    return;
  }

  if (sub === 'wallet' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改钱包页');
    const body = await readBody(req);
    const cfg = normalizeWallet(body.wallet || body);
    db.wallet = cfg;
    saveWallet();
    const cells = (cfg.groups || []).reduce((n, g) => n + (g.items || []).length, 0);
    audit(req, admin, 'wallet.save', '钱包页',
      (cfg.groups || []).length + ' 组 / ' + cells + ' 行 / 底部 ' + (cfg.footer || []).length + ' 个链接');
    sendToAll({ type: 'ui' });
    ok(res, { wallet: db.wallet });
    return;
  }

  /* ---------------- 零钱页（文案 / 按钮 / 链接 / 样式）---------------- */
  if (sub === 'balance-page' && method === 'GET') {
    ok(res, {
      page: db.balancePage || normalizeBalancePage(null),
      defaults: DEFAULT_BALANCE_PAGE,
      actions: BALANCE_ACTIONS
    });
    return;
  }

  if (sub === 'balance-page' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改零钱页');
    const body = await readBody(req);
    const cfg = normalizeBalancePage(body.page || body);
    db.balancePage = cfg;
    saveBalancePage();
    audit(req, admin, 'balance.save', '零钱页', cfg.title + ' / ' + (cfg.links || []).length + ' 个链接');
    sendToAll({ type: 'ui' });
    ok(res, { page: db.balancePage });
    return;
  }

  /* ---------------- 账单页样式（图标大小 / 字号 / 行高）---------------- */
  if (sub === 'bills-page' && method === 'GET') {
    ok(res, {
      page: db.billsPage || normalizeBillsPage(null),
      defaults: DEFAULT_BILLS_PAGE
    });
    return;
  }

  if (sub === 'bills-page' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改账单页');
    const body = await readBody(req);
    const cfg = normalizeBillsPage(body.page || body);
    db.billsPage = cfg;
    saveBillsPage();
    audit(req, admin, 'bills.save', '账单页样式', JSON.stringify(cfg.style));
    sendToAll({ type: 'ui' });
    ok(res, { page: db.billsPage });
    return;
  }

  /* ---------------- UI 图标（换成自定义的）---------------- */
  if (sub === 'icons' && method === 'GET') {
    const defs = readJson(path.join(DATA_DIR, 'icon-defaults.json'), { items: [] });
    ok(res, {
      defaults: defs.items || [],
      overrides: readJson(path.join(DATA_DIR, ICONS_FILE), {})
    });
    return;
  }

  if (sub === 'icons' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能改 UI 图标');
    const body = await readBody(req);
    const key = str(body.key, 40);
    if (!key) return fail(res, 422, '缺少图标标识');
    const value = String(body.value == null ? '' : body.value).slice(0, 300000).trim();
    const all = readJson(path.join(DATA_DIR, ICONS_FILE), {});
    const old = all[key] || '';
    if (value) all[key] = value; else delete all[key];
    writeJson(path.join(DATA_DIR, ICONS_FILE), all);
    callTrace('换图标 ' + key + ' → ' + (value ? value.slice(0, 70) : '（还原内置）'));
    audit(req, admin, value ? '更换 UI 图标' : '恢复默认图标', str(body.name, 40) || key,
      value ? (value.indexOf('<svg') === 0 ? '自定义 SVG' : value.slice(0, 60)) : '恢复内置图标');
    /* 立刻告诉所有在线客户端「界面配置变了」：App 收到就重新拉一次，
       不用让用户划掉重开才看到新图标。 */
    sendToAll({ type: 'ui' });
    ok(res, { saved: true, before: old, now: value });
    return;
  }

  /* ---------------- 公众号（后台：建号 / 发文章 / 看列表） ---------------- */
  if (sub === 'oa-list' && method === 'GET') {
    const oa = readOA();
    const follows = readOAFollows();
    ok(res, {
      accounts: oa.accounts.map((a) => Object.assign({}, a, {
        followers: follows.filter((f) => f.accountId === a.id).length,
        articleCount: oa.articles.filter((x) => x.accountId === a.id).length
      })),
      articles: oa.articles.slice(-100).reverse()
    });
    return;
  }

  if (sub === 'oa-account' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改公众号的权限');
    const body = await readBody(req);
    const oa = readOA();
    const id = str(body.id, 40);
    const name = str(body.name, 30).trim();
    const type = String(body.type || 'subscribe') === 'service' ? 'service' : 'subscribe';
    if (!name) return fail(res, 422, '公众号名字不能为空');
    let acc = id ? oa.accounts.find((a) => a.id === id) : null;
    if (acc) {
      acc.name = name;
      acc.type = type;
      acc.avatar = str(body.avatar, 200).trim();
      acc.bio = str(body.bio, 200).trim();
      if (body.enabled !== undefined) acc.enabled = !!body.enabled;
    } else {
      acc = {
        id: uid('oa'), name: name, type: type,
        avatar: str(body.avatar, 200).trim(), bio: str(body.bio, 200).trim(),
        enabled: body.enabled === undefined ? true : !!body.enabled, createdAt: now()
      };
      oa.accounts.push(acc);
    }
    saveOA(oa);
    if (acc.type === 'service') ensureOAUser(acc);      // 服务号要自己那条会话
    audit(req, admin, '保存公众号', acc.name, acc.type === 'service' ? '服务号' : '订阅号');
    ok(res, { account: acc });
    return;
  }

  if (sub === 'oa-publish' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有发文章的权限');
    const body = await readBody(req);
    const oa = readOA();
    const acc = oa.accounts.find((a) => a.id === str(body.accountId, 40));
    if (!acc) return fail(res, 404, '公众号不存在');
    const title = str(body.title, 80).trim();
    if (!title) return fail(res, 422, '标题不能为空');
    const art = {
      id: uid('art'), accountId: acc.id, title: title,
      summary: str(body.summary, 200).trim(),
      cover: str(body.cover, 300).trim(),
      author: str(body.author, 30).trim(),
      content: String(body.content || '').slice(0, 60000),
      originalUrl: str(body.originalUrl, 300).trim(),
      createdAt: now(), reads: 0
    };
    oa.articles.push(art);
    saveOA(oa);
    const sent = body.push === false ? 0 : oaPublish(acc, art);
    audit(req, admin, '发公众号文章', acc.name + ' · ' + title, '推送 ' + sent + ' 人');
    ok(res, { article: art, sent: sent });
    return;
  }

  /* 删掉一篇文章（后台列表里那个删除按钮；客户端跟着就看不到这篇了） */
  if (sub === 'oa-article-delete' && method === 'POST') {
    if (!can(admin, 'ops.write')) return fail(res, 403, '你的角色没有改公众号的权限');
    const body = await readBody(req);
    const oa = readOA();
    const id = str(body.id, 40);
    const at = oa.articles.findIndex((x) => x.id === id);
    if (at < 0) return fail(res, 404, '这篇文章已经不存在了（刷新一下看看）');
    const gone = oa.articles.splice(at, 1)[0];
    saveOA(oa);
    audit(req, admin, '删除公众号文章', gone.title, gone.accountId);
    ok(res, { deleted: gone.id, accountId: gone.accountId });
    return;
  }

  /* 后台里上传图标文件（存到同一个 uploads 目录） */
  if (sub === 'upload' && method === 'POST') {
    if (!can(admin, 'icons.write')) return fail(res, 403, '只有超级管理员能上传图标');
    const body = await readBody(req);
    callTrace('图标上传：' + str(body.filename, 60) + ' 大小=' + String(body.dataUrl || '').length
      + ' 类型=' + String(body.dataUrl || '').slice(0, 24));
    const saved = saveUploadedFile(body);
    if (saved.error) { callTrace('图标上传失败：' + saved.error); return fail(res, saved.status, saved.error); }
    callTrace('图标上传成功：' + saved.url);
    audit(req, admin, '上传图标文件', saved.url, saved.name || '');
    ok(res, saved);
    return;
  }

  /* ---------------- 后台账号管理 ---------------- */
  if (sub === 'admins' && method === 'GET') {
    if (!can(admin, 'admins')) return fail(res, 403, '只有超级管理员能看账号列表');
    ok(res, {
      admins: opsStore.admins.map((a) => ({
        id: a.id, username: a.username, name: a.name,
        role: a.role, roleName: OPS_ROLE_NAMES[a.role] || a.role,
        disabled: !!a.disabled, createdAt: a.createdAt,
        lastLoginAt: a.lastLoginAt || '', lastIp: a.lastIp || ''
      })),
      roles: Object.keys(OPS_ROLES).map((r) => ({ key: r, name: OPS_ROLE_NAMES[r] }))
    });
    return;
  }

  if (sub === 'admins' && method === 'POST') {
    if (!can(admin, 'admins')) return fail(res, 403, '只有超级管理员能加账号');
    const body = await readBody(req);
    const username = str(body.username, 24).toLowerCase();
    const password = String(body.password || '').trim();
    if (!/^[a-z0-9_]{3,24}$/.test(username)) return fail(res, 422, '账号要 3-24 位字母/数字/下划线');
    if (password.length < 6) return fail(res, 422, '密码至少 6 位');
    if (opsStore.admins.some((a) => a.username === username)) return fail(res, 409, '这个账号已经存在');
    const role = OPS_ROLES[body.role] ? body.role : 'support';
    const salt = crypto.randomBytes(16).toString('hex');
    const item = {
      id: uid('ops'), username, name: str(body.name, 20) || username, role,
      salt, hash: hashPassword(password, salt), createdAt: now(), disabled: false
    };
    opsStore.admins.push(item);
    saveOpsAdmins();
    audit(req, admin, '新增后台账号', username, OPS_ROLE_NAMES[role]);
    ok(res, { admin: opsMe(item) });
    return;
  }

  /* 改自己的后台密码（要提供原密码）；强密码要求至少 10 位、含字母和数字 */
  if (sub === 'password' && method === 'POST') {
    const body = await readBody(req);
    const cur = String(body.current || '');
    const next = String(body.next || '').trim();
    if (!verifySecretRecord({ salt: admin.salt, hash: admin.hash }, cur)) {
      audit(req, admin, '改密码失败', admin.username, '原密码不对');
      return fail(res, 401, '原密码不正确');
    }
    if (next.length < 10 || !/[A-Za-z]/.test(next) || !/[0-9]/.test(next)) {
      return fail(res, 422, '新密码至少 10 位，且要同时有字母和数字');
    }
    admin.salt = crypto.randomBytes(16).toString('hex');
    admin.hash = hashPassword(next, admin.salt);
    saveOpsAdmins();
    audit(req, admin, '修改后台密码', admin.username, '');
    ok(res, { changed: true });
    return;
  }

  if (sub === 'admins' && parts[3] === 'disable' && method === 'POST') {
    if (!can(admin, 'admins')) return fail(res, 403, '只有超级管理员能改账号');
    const a = opsStore.admins.find((x) => x.id === parts[2]);
    if (!a) return fail(res, 404, '账号不存在');
    if (a.id === admin.id) return fail(res, 422, '不能停用自己');
    const body = await readBody(req);
    a.disabled = !!body.disabled;
    saveOpsAdmins();
    audit(req, admin, a.disabled ? '停用后台账号' : '启用后台账号', a.username, '');
    ok(res, { disabled: a.disabled });
    return;
  }

  /* 生成一次性免密登录链接（只有超管）：POST { username, minutes } → { url }
     用来「点开就进某个角色的后台」，不用输密码。5 分钟过期、用一次就废。 */
  if (sub === 'magic' && method === 'POST') {
    if (!can(admin, 'admins')) return fail(res, 403, '只有超级管理员能生成免密链接');
    const body = await readBody(req);
    const target = opsStore.admins.find((a) => a.username === str(body.username, 24).toLowerCase() && !a.disabled);
    if (!target) return fail(res, 404, '没有这个后台账号');
    const token = newMagicToken(target.id, Number(body.minutes) || 5);
    const key = String(secCfg().adminKey || '');
    const host = str(body.host, 60).replace(/[^0-9A-Za-z\.\-:]/g, '') || String(req.headers.host || '').split(':')[0] || '192.168.2.7';
    audit(req, admin, '生成免密登录链接', target.username, '角色 ' + target.role);
    ok(res, {
      url: 'https://' + host + ':5443/manage.html?k=' + encodeURIComponent(key) + '&m=' + token,
      username: target.username, role: target.role, roleName: OPS_ROLE_NAMES[target.role] || target.role,
      expiresInSeconds: 300
    });
    return;
  }

  fail(res, 404, '接口不存在');
}

loadOps();
/* ---------------------------------------------------------------- 地图
   位置搜索可以走高德（后台填一个「Web 服务」Key 即可，免费申请）。
   没填 Key 时接口返回 503，客户端自动退回系统地图搜索。
   高德用的是 GCJ-02，我们客户端底图是 WGS-84，所以这里要换算回去。 */
const GEO_FILE = 'geo.json';
let geoCache = null;
function readGeo() {
  if (!geoCache) geoCache = readJson(path.join(DATA_DIR, GEO_FILE), {}) || {};
  return geoCache;
}
function saveGeo(patch) {
  geoCache = Object.assign({}, readGeo(), patch || {});
  writeJson(path.join(DATA_DIR, GEO_FILE), geoCache);
  return geoCache;
}
/* GCJ-02 → WGS-84（高德给的点 → 我们地图上的点）。
   正向变换没有解析解，用"迭代逼近"：把 WGS 猜出来再正算，误差收敛到米级。 */
function gcj02ToWgs84(gLat, gLng) {
  const outOfChina = (lat, lng) => (lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271);
  if (!gLat || !gLng || outOfChina(gLat, gLng)) return { lat: gLat, lng: gLng };
  let lat = gLat, lng = gLng;
  for (let i = 0; i < 6; i += 1) {
    const f = wgs84ToGcj02(lat, lng);
    lat += (gLat - f.lat);
    lng += (gLng - f.lng);
  }
  return { lat: lat, lng: lng };
}
function wgs84ToGcj02(lat, lng) {
  const a = 6378245.0, ee = 0.00669342162296594323;
  const tLat = (x, y) => {
    let ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(Math.abs(x));
    ret += (20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0 / 3.0;
    ret += (20.0 * Math.sin(y * Math.PI) + 40.0 * Math.sin(y / 3.0 * Math.PI)) * 2.0 / 3.0;
    ret += (160.0 * Math.sin(y / 12.0 * Math.PI) + 320 * Math.sin(y * Math.PI / 30.0)) * 2.0 / 3.0;
    return ret;
  };
  const tLng = (x, y) => {
    let ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x));
    ret += (20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0 / 3.0;
    ret += (20.0 * Math.sin(x * Math.PI) + 40.0 * Math.sin(x / 3.0 * Math.PI)) * 2.0 / 3.0;
    ret += (150.0 * Math.sin(x / 12.0 * Math.PI) + 300.0 * Math.sin(x / 30.0 * Math.PI)) * 2.0 / 3.0;
    return ret;
  };
  let dLat = tLat(lng - 105.0, lat - 35.0);
  let dLng = tLng(lng - 105.0, lat - 35.0);
  const radLat = lat / 180.0 * Math.PI;
  let magic = Math.sin(radLat);
  magic = 1 - ee * magic * magic;
  const sqrtMagic = Math.sqrt(magic);
  dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * Math.PI);
  dLng = (dLng * 180.0) / (a / sqrtMagic * Math.cos(radLat) * Math.PI);
  return { lat: lat + dLat, lng: lng + dLng };
}

/* ---------------------------------------------------------------- 毒链接
  只允许「正常网址」：域名/路径里带黄赌毒、电诈特征的链接一律拦下来。
   中文词走上面的敏感词库（sensitive.json），这里补英文域名常见的那批。
   ⚠ 英文词只按「域名分段」匹配（bet365.com ✓、alphabet.com ✗），尽量不误伤。 */
const LINK_BAD_HOST_WORDS = [
  'casino', 'poker', 'baccarat', 'roulette', 'gambling', 'lottery', 'lotto', 'jackpot',
  'sportsbook', 'jili', 'jdb', 'slot', 'betting', 'porn', 'xxx', 'hentai', 'onlyfans',
  'escort', 'nude', 'naked', 'adult', 'camgirl', 'cocaine', 'heroin', 'meth'
];
const LINK_BAD_LABELS = ['bet', 'sex', 'xxx', 'porn', 'win', 'toto', '18', 'av', '4d'];
/* 短词光靠"分段相等"拦不住 18av.com / 91porn.com 这种拼起来的域名，补两条正则 */
const LINK_BAD_LABEL_RE = [
  /^(18|91|av|jav)?(av|jav|porn|xxx|sex|adult|hentai|onlyfans)\d*$/i,
  /^\d{0,2}(av|xxx|porn|sex)\d*$/i
];
const LINK_BAD_PATH_WORDS = [
  '/casino', '/bet', '/poker', '/lottery', '/gamble', '/porn', '/xxx', '/sex', '/adult', '/hentai'
];

function badLinkHit(text) {
  const s = String(text || '');
  if (!s) return '';
  const urls = s.match(/(?:https?:\/\/|www\.)[^\s，。、）)】」<>"']+/gi)
    || s.match(/(?:[A-Za-z0-9-]+\.)+(?:com|cn|net|org|io|cc|me|tv|xyz|top|vip|shop|info|edu|gov|co|app|dev|bet|casino|porn|xxx|sex)(?:\/[^\s，。、）)】」<>"']*)?/gi)
    || [];
  for (const raw of urls) {
    const low = raw.toLowerCase().replace(/^https?:\/\//, '').replace(/^www\./, '');
    const host = low.split('/')[0].split('?')[0];
    const labels = host.split('.');
    for (const w of LINK_BAD_HOST_WORDS) {
      if (host.indexOf(w) >= 0) return w;
    }
    for (const w of LINK_BAD_LABELS) {
      const hit = labels.some((lb) => lb === w
        || lb.indexOf(w + '-') === 0 || lb.indexOf('-' + w) >= 0
        || new RegExp('^' + w + '\\d*$').test(lb));
      if (hit) return w;
    }
    for (const re of LINK_BAD_LABEL_RE) {
      const hit = labels.find((lb) => re.test(lb));
      if (hit) return hit;
    }
    for (const p of LINK_BAD_PATH_WORDS) {
      if (low.indexOf(p) >= 0) return p.replace('/', '');
    }
  }
  return '';
}
