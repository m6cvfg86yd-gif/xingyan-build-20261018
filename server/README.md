# 服务端（自建聊天服务器）

这是线上服务器 `root@206.187.208.79` 上 `/opt/chris/app/` 的源码副本。
以前服务端只存在于那台机器上、没有任何版本管理——机器一坏就全没了，所以同步进这里。

## 目录对应关系

| 仓库 | 线上 | 说明 |
|---|---|---|
| `server/server.js` | `/opt/chris/app/server.js` | 全部后端逻辑（HTTP + WebSocket + 业务），单文件，约 780KB |
| `server/public/` | `/opt/chris/app/public/` | 网页版 / 管理后台 / 下载页（`index.html`、`m.html`+`m.js` 是手机网页通话端、`manage.html` 是新后台） |
| `server/lib/ws.js` | `/opt/chris/app/lib/ws.js` | WebSocket 实现 |
| `server/*-shrink.js`、`hls-build.js` | 同路径 | 运维脚本：媒体瘦身、视频切 HLS |
| **`data/`（不在仓库里）** | `/opt/chris/app/data/` | 用户、聊天、上传文件、`secret.key`、管理员密码哈希——**故意不入库** |

## 运行方式

systemd 单元 `/etc/systemd/system/chris.service`：

```
WorkingDirectory=/opt/chris/app
ExecStart=/usr/local/bin/node server.js
Restart=always
Environment=PORT=5180
```

* 前台/网页：`http://127.0.0.1:5180/`
* 手机网页通话端：`https://<服务器>:5443/m.html`（App 通话必须用 HTTPS 地址）
* 管理后台：`/manage.html`（新，走 `/api/ops`）、`/admin.html`（老，走 `/api/admin`）
* 公网入口：HTTP 5180 / HTTPS 5443

改完 `server.js` 或 `public/` 后要 `systemctl restart chris`（约 2~5 秒抖动，客户端会自动重连，通话有 20 秒宽限期）。

## 音视频通道（踩过的坑，别再踩一遍）

| 通道 | 走什么 |
|---|---|
| 语音通话 | **优先腾讯云 TRTC**，自建转发兜底（见下） |
| 视频通话 | **腾讯云 TRTC**（`/api/trtc/sig` 签发；密钥只在服务端 `data/trtc.json`） |
| 直播 | 自建 WebRTC（用同一份 `iceServers`） |

**语音的双通道逻辑**（B499 起）：两端都**先进 TRTC 房间但不采集**，同时自建转发通道照常跑着；
等确认「对端也在同一个房间里」，客户端才 `switchMediaToTRTC()`——先停掉自建采集/播放，
再让 TRTC 开麦。所以：

* 两台新版 App → 语音走腾讯云（音质/抖动/回声消除都由 TRTC 负责，不吃服务器带宽）
* 对端是旧版 App 或网页版（不会进 TRTC 房间）→ 自动留在自建转发，不会打不通
* `data/trtc.json` 里把 `voiceEnabled` 设成 `false` → 服务端对语音的签名请求直接返回失败，
  客户端自动退回自建转发（**一键回退，不用重装 App**）
* ⚠️ `data/trtc.json` 里记着「体验版 2026-09-30 到期」——到期后腾讯这条会失效，
  语音/视频会自动退回可用通道（语音退自建转发），但视频没有自建退路，得先续费或另想办法

自建转发通道本身：App 采集 16kHz 单声道 PCM（40ms 一帧）→ base64 → WebSocket `action:"audio"` → 服务端原样转给对端

**TURN/STUN**：用系统 coturn（`/etc/turnserver.conf`，`external-ip=206.187.208.79/10.0.246.2`）。

* `turn:aa.x8iu.com:3478?transport=tcp` ✅ 可用（实测 TURN ALLOCATE 成功）
* `turn:...?transport=udp` ❌ **机房整段屏蔽入站 UDP**（用 tcpdump 实测：24 个 UDP 包一个都没到）
* `turns:aa.x8iu.com:443?transport=tcp` ❌ 不可用——iptables 把 443 重定向到了 5443：
  `-A PREROUTING -p tcp --dport 443 -j REDIRECT --to-ports 5443`，coturn 根本收不到
* `stun:aa.x8iu.com:3478` ❌ 同理（STUN 走 UDP），**必须用公网 STUN**
* ⚠️ **不要补 `turn.js`**：`server.js` 启动时会尝试 `require('./turn.js')`，失败只打一行日志、无害；补上它会跟系统 coturn 抢 3478 端口

**ICE 配置放在 `data/branding.json` 的 `branding.iceServers`**（一个 JSON 字符串），改完要重启才生效（服务端在内存里缓存）。
注意它有两个坑：

1. 顶层那个 `iceServers` 是历史误写，**没有任何代码读它**（服务端只读 `db.branding.iceServers`）。
2. iOS 端 `CallCenter.loadIce()` 的行为是——只要服务端下发了非空 `iceServers`，就**整份替换**客户端内置的公共 STUN。所以这份配置里**必须包含可用 STUN**，否则两端都拿不到公网候选（`srflx=0`），所有通话被迫全量走中继。

当前线上值（2026-09-24 修）：

```json
[{"urls":["stun:stun.miwifi.com:3478","stun:stun.chat.bilibili.com:3478","stun:stun.l.google.com:19302"]},
 {"urls":["turn:aa.x8iu.com:3478?transport=tcp"],"username":"chris","credential":"chris1234"}]
```

改完用真实浏览器验一次：`work/ice-e2e.mjs` 会把线上配置喂给无头 Chrome 收集 ICE 候选，`srflx >= 1` 才算正常。

## 管理接口

* `/api/branding` GET 公开只读；PUT 需要管理员会话（`POST /api/admin/login`）
* `/api/admin/*` 仅允许局域网 IP + HTTPS（本机 `127.0.0.1` 豁免，所以脚本走 `curl -k https://127.0.0.1:5443/...`）
* `/api/ops/*` 是新后台，角色分 super / auditor / support / ops，高危操作要带 `confirmPassword`
* 管理员密码是 scrypt 哈希（`data/admin.json`），**不可逆**；忘了只能改文件重置

## 出包与发布

* iOS 出包：GitHub Actions `build-ios`（`macos-14`）。**公开仓库 macOS 分钟免费；私有仓库会计费，额度/账单有问题时任务会秒失败**（报 `The job was not started because recent account payments have failed...`）。
* 发布脚本：`work/publish-ipa.ps1`（用 `pwsh` 跑，不要用 PowerShell 5.1——UTF-8 中文会乱码）。它做四件事：拉 CI 产物 → `openssl` 解密 → 校验 PK 头 → `scp` 覆盖 `/opt/chris/app/public/Luchat.ipa`（并留时间戳备份）。
* 下载页与 App 内更新都读 `/public/Luchat.ipa`，覆盖即发布。

## 还没同步进来的

* `data/`（用户数据，永远不入库）
* `tls/`（`server.pfx` + `pass.txt`）和 `/etc/coturn-certs/privkey.pem`——**私钥，绝对不入库**
* `server.js` 的几十个历史 `.bak-*`（服务器上留着，需要时单独取）
