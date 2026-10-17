/* 存量素材瘦身（跑在服务器上）：
   · 视频 > 2.5MB：按「源码率 × 0.75」（夹在 400k~1400k）重压成 720p / faststart，
     变小了才替换（原名替换 = 消息里的地址不用改）；原文件先备份到 /opt/chris/media-orig
   · 图片 > 600KB：不透明的（截图/照片）转成 JPEG（长边≤1600, q4）；有透明通道的跳过
   用法：node media-shrink.js  [--videos-only|--images-only] */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');
const D = '/opt/chris/app/data/';
const UP = D + 'uploads/';
const BAK = '/opt/chris/media-orig/';
const secret = fs.readFileSync(D + 'secret.key', 'utf8').trim();
const MAGIC = Buffer.from('LUC1');
const key = (n) => crypto.createHmac('sha256', secret).update('file:' + n).digest();
function open(name) {
  const raw = fs.readFileSync(UP + name);
  if (raw.length < 20 || !raw.subarray(0, 4).equals(MAGIC)) return { plain: raw, sealed: false };
  const d = crypto.createDecipheriv('aes-256-ctr', key(name), raw.subarray(4, 20));
  return { plain: Buffer.concat([d.update(raw.subarray(20)), d.final()]), sealed: true };
}
function seal(name, buf) {
  const iv = crypto.randomBytes(16);
  const c = crypto.createCipheriv('aes-256-ctr', key(name), iv);
  const out = Buffer.concat([MAGIC, iv, c.update(buf), c.final()]);
  const tmp = UP + name + '.tmp';
  fs.writeFileSync(tmp, out);
  fs.renameSync(tmp, UP + name);
}
function backup(name) {
  try {
    fs.mkdirSync(BAK, { recursive: true });
    if (!fs.existsSync(BAK + name)) fs.copyFileSync(UP + name, BAK + name);
  } catch (e) { }
}
const TMP = '/tmp/shrink2/';
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const probe = (args) => { try { return execFileSync('ffprobe', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch (e) { return ''; } };
const ff = (args) => { try { execFileSync('nice', ['-n', '15', 'ffmpeg'].concat(args), { stdio: ['ignore', 'ignore', 'ignore'] }); return true; } catch (e) { return false; } };

fs.mkdirSync(TMP, { recursive: true });
const only = process.argv[2] || '';
let vDone = 0, vSkip = 0, vSaved = 0, iDone = 0, iSkip = 0, iSaved = 0;

/* ---------------- 视频 ---------------- */
if (only !== '--images-only') {
  const vids = fs.readdirSync(UP).filter((f) => /\.(mp4|mov|m4v)$/i.test(f))
    .map((f) => ({ f: f, s: Math.max(0, fs.statSync(UP + f).size - 20) }))
    .filter((x) => x.s > 2.5 * 1048576)
    .sort((a, b) => b.s - a.s);
  log('待处理视频 ' + vids.length + ' 个，合计 ' + (vids.reduce((a, b) => a + b.s, 0) / 1048576).toFixed(0) + 'MB');
  for (const it of vids) {
    const src = TMP + it.f;
    let plain = null;
    try { plain = open(it.f).plain; } catch (e) { log('解密失败', it.f); continue; }
    fs.writeFileSync(src, plain);
    const dur = Number(probe(['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', src])) || 0;
    const dim = probe(['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'csv=p=0', src]).split(',');
    const w = Number(dim[0]) || 0, h = Number(dim[1]) || 0;
    const long = Math.max(w, h);
    if (!dur || !long) { log('探测失败，跳过', it.f); vSkip += 1; continue; }
    /* 目标码率：源码率的 75%，夹在 400k~1400k（源码率本来就低的，别硬压） */
    const srcKbps = it.s * 8 / dur / 1000;
    if (srcKbps <= 700) { log('源码率已经很低（' + Math.round(srcKbps) + 'k），跳过 ' + it.f); vSkip += 1; try { fs.unlinkSync(src); } catch (e) { } continue; }
    const target = Math.max(350, Math.min(900, Math.round(srcKbps * 0.45)));
    const out = src + '.small.mp4';
    const okRun = ff(['-y', '-loglevel', 'error', '-i', src,
      '-vf', "scale='if(gt(iw,ih),min(1024,iw),-2)':'if(gt(iw,ih),-2,min(1024,ih))'",
      '-c:v', 'libx264', '-profile:v', 'main', '-preset', 'veryfast', '-threads', '1',
      '-b:v', target + 'k', '-maxrate', Math.round(target * 1.3) + 'k', '-bufsize', (target * 2) + 'k',
      '-r', '30', '-g', '60', '-keyint_min', '60', '-sc_threshold', '0',
      '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '64k', '-ac', '1',
      '-movflags', '+faststart', out]);
    if (!okRun || !fs.existsSync(out)) { log('转码失败，保留原样', it.f); vSkip += 1; try { fs.unlinkSync(src); } catch (e) { } continue; }
    const small = fs.readFileSync(out);
    if (small.length >= it.s * 0.9) {
      log('压完没小多少（' + (it.s / 1048576).toFixed(1) + '→' + (small.length / 1048576).toFixed(1) + 'MB），保留原样 ' + it.f);
      vSkip += 1;
    } else {
      backup(it.f);
      seal(it.f, small);
      vSaved += it.s - small.length;
      vDone += 1;
      log('视频 ' + it.f + '  ' + (it.s / 1048576).toFixed(1) + 'MB → ' + (small.length / 1048576).toFixed(1)
        + 'MB  ' + w + 'x' + h + ' 源码率' + Math.round(srcKbps) + 'k→目标' + target + 'k');
    }
    try { fs.unlinkSync(out); } catch (e) { }
    try { fs.unlinkSync(src); } catch (e) { }
  }
  log('视频完成：压了 ' + vDone + ' 个，跳过 ' + vSkip + ' 个，省 ' + (vSaved / 1048576).toFixed(1) + 'MB');
}

/* ---------------- 图片 ---------------- */
if (only !== '--videos-only') {
  const imgs = fs.readdirSync(UP).filter((f) => /\.(jpg|jpeg|png|webp)$/i.test(f))
    .map((f) => ({ f: f, s: Math.max(0, fs.statSync(UP + f).size - 20) }))
    .filter((x) => x.s > 600 * 1024)
    .sort((a, b) => b.s - a.s);
  log('待处理图片 ' + imgs.length + ' 张，合计 ' + (imgs.reduce((a, b) => a + b.s, 0) / 1048576).toFixed(0) + 'MB');
  for (const it of imgs) {
    let plain = null;
    try { plain = open(it.f).plain; } catch (e) { continue; }
    const isPng = plain.subarray(0, 8).toString('hex') === '89504e470d0a1a0a';
    if (isPng) {
      const ct = plain[25];                     // 4/6 = 有透明通道（贴纸那种），别动
      if (ct === 4 || ct === 6) { log('有透明通道，跳过', it.f); iSkip += 1; continue; }
    }
    const src = TMP + it.f;
    fs.writeFileSync(src, plain);
    const out = src + '.small.jpg';
    /* 统一转成 JPEG（长边 ≤1600，q4 ≈ 原图 1/6 体积）：截图和照片都够看 */
    const okRun = ff(['-y', '-loglevel', 'error', '-i', src,
      '-vf', "scale='if(gt(iw,ih),min(1600,iw),-2)':'if(gt(iw,ih),-2,min(1600,ih))'",
      '-q:v', '4', '-f', 'mjpeg', out]);
    if (!okRun || !fs.existsSync(out)) { log('转码失败，保留原样', it.f); iSkip += 1; try { fs.unlinkSync(src); } catch (e) { } continue; }
    const small = fs.readFileSync(out);
    if (small.length >= it.s * 0.8) {
      log('压完没小多少，保留原样 ' + it.f);
      iSkip += 1;
    } else {
      backup(it.f);
      seal(it.f, small);                        // 仍用原文件名（消息里的地址不变）
      iSaved += it.s - small.length;
      iDone += 1;
      log('图片 ' + it.f + '  ' + (it.s / 1024).toFixed(0) + 'KB → ' + (small.length / 1024).toFixed(0) + 'KB');
    }
    try { fs.unlinkSync(out); } catch (e) { }
    try { fs.unlinkSync(src); } catch (e) { }
  }
  log('图片完成：压了 ' + iDone + ' 张，跳过 ' + iSkip + ' 张，省 ' + (iSaved / 1048576).toFixed(1) + 'MB');
}
