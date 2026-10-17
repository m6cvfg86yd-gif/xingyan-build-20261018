/* 第二轮：把码率还偏高的视频再压一档（首段更小 = 更快出画面）
   规则：码率 > 800k 或体积 > 1.2MB → 压到 clamp(源码率×0.55, 300k, 650k)，长边 ≤1024，GOP 2 秒 */
const fs = require('fs');
const crypto = require('crypto');
const { execFileSync } = require('child_process');
const D = '/opt/chris/app/data/';
const UP = D + 'uploads/';
const BAK = '/opt/chris/media-orig/';
const secret = fs.readFileSync(D + 'secret.key', 'utf8').trim();
const MAGIC = Buffer.from('LUC1');
const key = (n) => crypto.createHmac('sha256', secret).update('file:' + n).digest();
function openName(name) {
  const raw = fs.readFileSync(UP + name);
  if (raw.length < 20 || !raw.subarray(0, 4).equals(MAGIC)) return raw;
  const d = crypto.createDecipheriv('aes-256-ctr', key(name), raw.subarray(4, 20));
  return Buffer.concat([d.update(raw.subarray(20)), d.final()]);
}
function seal(name, buf) {
  const iv = crypto.randomBytes(16);
  const c = crypto.createCipheriv('aes-256-ctr', key(name), iv);
  const tmp = UP + name + '.tmp';
  fs.writeFileSync(tmp, Buffer.concat([MAGIC, iv, c.update(buf), c.final()]));
  fs.renameSync(tmp, UP + name);
}
const TMP = '/tmp/shrink3/';
fs.mkdirSync(TMP, { recursive: true });
fs.mkdirSync(BAK, { recursive: true });
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const probe = (a) => { try { return execFileSync('ffprobe', a, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); } catch (e) { return ''; } };

const vids = fs.readdirSync(UP).filter((f) => /\.(mp4|mov|m4v)$/i.test(f))
  .map((f) => ({ f: f, s: Math.max(0, fs.statSync(UP + f).size - 20) }))
  .sort((a, b) => b.s - a.s);
let done = 0, skip = 0, saved = 0;
for (const it of vids) {
  const src = TMP + it.f;
  let plain;
  try { plain = openName(it.f); } catch (e) { continue; }
  fs.writeFileSync(src, plain);
  const dur = Number(probe(['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', src])) || 0;
  if (!dur) { skip += 1; try { fs.unlinkSync(src); } catch (e) { } continue; }
  const kbps = it.s * 8 / dur / 1000;
  if (kbps <= 800 && it.s <= 1.2 * 1048576) { skip += 1; try { fs.unlinkSync(src); } catch (e) { } continue; }
  const target = Math.max(300, Math.min(650, Math.round(kbps * 0.55)));
  const out = src + '.v2.mp4';
  let ok = true;
  try {
    execFileSync('nice', ['-n', '15', 'ffmpeg', '-y', '-loglevel', 'error', '-i', src,
      '-vf', "scale='if(gt(iw,ih),min(1024,iw),-2)':'if(gt(iw,ih),-2,min(1024,ih))'",
      '-c:v', 'libx264', '-profile:v', 'main', '-preset', 'veryfast', '-threads', '1',
      '-b:v', target + 'k', '-maxrate', Math.round(target * 1.3) + 'k', '-bufsize', (target * 2) + 'k',
      '-r', '30', '-g', '60', '-keyint_min', '60', '-sc_threshold', '0',
      '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '64k', '-ac', '1',
      '-movflags', '+faststart', out], { stdio: ['ignore', 'ignore', 'ignore'] });
  } catch (e) { ok = false; }
  if (!ok || !fs.existsSync(out)) { log('转码失败，保留', it.f); skip += 1; try { fs.unlinkSync(src); } catch (e) { } continue; }
  const small = fs.readFileSync(out);
  if (small.length >= it.s * 0.92) {
    skip += 1;
  } else {
    try { if (!fs.existsSync(BAK + it.f)) fs.copyFileSync(UP + it.f, BAK + it.f); } catch (e) { }
    seal(it.f, small);
    saved += it.s - small.length;
    done += 1;
    log('视频 ' + it.f + '  ' + (it.s / 1048576).toFixed(1) + 'MB→' + (small.length / 1048576).toFixed(1)
      + 'MB  ' + Math.round(kbps) + 'k→' + target + 'k  ' + Math.round(dur) + 's');
  }
  try { fs.unlinkSync(out); } catch (e) { }
  try { fs.unlinkSync(src); } catch (e) { }
}
log('第二轮完成：压了 ' + done + ' 个，跳过 ' + skip + ' 个，省 ' + (saved / 1048576).toFixed(1) + 'MB');
