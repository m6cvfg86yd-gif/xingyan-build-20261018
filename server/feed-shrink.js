/* 视频号瘦身：把 /uploads 里的大视频转成「手机上刷得动」的规格
   720p 长边≤1280 / 约 1.2Mbps / 30fps / AAC 96k / faststart，并补封面。
   上传目录是密文，先解到临时文件再转，转完再加密写回；原文件保留不删。 */
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFileSync } = require('child_process');
const D = '/opt/chris/app/data/';
const UP = D + 'uploads/';
const secret = fs.readFileSync(D + 'secret.key', 'utf8').trim();
const key = (name) => crypto.createHmac('sha256', secret).update('file:' + name).digest();
const MAGIC = Buffer.from('LUC1');
function open(name) {
  const raw = fs.readFileSync(UP + name);
  if (raw.length < 20 || !raw.subarray(0, 4).equals(MAGIC)) return raw;
  const d = crypto.createDecipheriv('aes-256-ctr', key(name), raw.subarray(4, 20));
  return Buffer.concat([d.update(raw.subarray(20)), d.final()]);
}
function seal(name, buf) {
  const iv = crypto.randomBytes(16);
  const c = crypto.createCipheriv('aes-256-ctr', key(name), iv);
  fs.writeFileSync(UP + name, Buffer.concat([MAGIC, iv, c.update(buf), c.final()]));
}
const newName = (ext) => 'file_' + crypto.randomBytes(8).toString('hex') + ext;
const probe = (args) => { try { return execFileSync('ffprobe', args, { encoding: 'utf8' }).trim(); } catch (e) { return ''; } };
const SIZE_LIMIT = 1.6 * 1048576;
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);

(async () => {
  const F = D + 'feed.json';
  const cfg = JSON.parse(fs.readFileSync(F, 'utf8'));
  const items = (cfg.posts || []).concat(cfg.items || []);
  const jobs = [];
  const seen = new Set();
  items.forEach((it) => {
    const v = String(it.video || '');
    if (v.indexOf('/uploads/') !== 0) return;
    const n = path.basename(v);
    if (seen.has(n)) return;
    seen.add(n);
    let st;
    try { st = fs.statSync(UP + n); } catch (e) { return; }
    jobs.push({ name: n, size: Math.max(0, st.size - 20), ids: [] });
  });
  items.forEach((it) => {
    const n = path.basename(String(it.video || ''));
    const j = jobs.find((x) => x.name === n);
    if (j) j.ids.push(it.id);
  });
  let done = 0, skipped = 0, saved = 0, failed = 0;
  const changed = new Map();   // id -> { video, cover }
  for (const j of jobs) {
    const tmpIn = '/tmp/shrink/' + j.name;
    fs.mkdirSync('/tmp/shrink', { recursive: true });
    let buf;
    try { buf = open(j.name); } catch (e) { log('解密失败', j.name, e.message); failed += 1; continue; }
    fs.writeFileSync(tmpIn, buf);
    const res = probe(['-v','error','-select_streams','v:0','-show_entries','stream=width,height,duration','-of','csv=p=0', tmpIn]).split(',');
    const w = Number(res[0]) || 0, h = Number(res[1]) || 0;
    const long = Math.max(w, h);
    if (buf.length <= SIZE_LIMIT && long <= 1280) {
      skipped += 1;
      fs.unlinkSync(tmpIn);
      log('够小，跳过', j.name, (buf.length/1048576).toFixed(1) + 'MB', w + 'x' + h);
      continue;
    }
    const outTmp = tmpIn + '.small.mp4';
    const t0 = Date.now();
    let okOut = false;
    try {
      execFileSync('nice', ['-n','10','ffmpeg','-y','-loglevel','error','-i',tmpIn,
        '-vf', "scale='if(gt(iw,ih),min(1280,iw),-2)':'if(gt(iw,ih),-2,min(1280,ih))'",
        '-c:v','libx264','-profile:v','high','-preset','veryfast',
        '-b:v','1200k','-maxrate','1500k','-bufsize','3000k',
        '-r','30','-g','60','-keyint_min','60','-sc_threshold','0',
        '-pix_fmt','yuv420p','-c:a','aac','-b:a','96k','-ac','1',
        '-movflags','+faststart', outTmp], { stdio: ['ignore','ignore','inherit'] });
      okOut = fs.existsSync(outTmp);
    } catch (e) { okOut = false; }
    if (!okOut) {
      failed += 1;
      log('转码失败，保留原文件', j.name);
      try { fs.unlinkSync(tmpIn); } catch (e) { }
      continue;
    }
    const outBuf = fs.readFileSync(outTmp);
    const outName = newName('.mp4');
    seal(outName, outBuf);
    saved += j.size - outBuf.length;
    done += 1;
    /* 封面：原来没有就抽第一帧 */
    let coverName = '';
    for (const it of items) {
      if (j.ids.indexOf(it.id) < 0) continue;
      if (String(it.cover || '').indexOf('/uploads/') === 0) { coverName = path.basename(it.cover); break; }
    }
    if (!coverName) {
      const cTmp = tmpIn + '.cover.jpg';
      try {
        execFileSync('ffmpeg', ['-y','-loglevel','error','-ss','0.3','-i',tmpIn,'-frames:v','1',
          '-vf','scale=576:-2','-q:v','6', cTmp], { stdio: ['ignore','ignore','ignore'] });
        if (fs.existsSync(cTmp)) { coverName = newName('.jpg'); seal(coverName, fs.readFileSync(cTmp)); fs.unlinkSync(cTmp); }
      } catch (e) { }
    }
    j.ids.forEach((id) => changed.set(id, { video: '/uploads/' + outName, cover: coverName ? '/uploads/' + coverName : '' }));
    log('压缩 ' + j.name + ' ' + (j.size/1048576).toFixed(1) + 'MB → ' + (outBuf.length/1048576).toFixed(1)
      + 'MB  ' + w + 'x' + h + ' → 长边≤1280  ' + Math.round((Date.now() - t0)/1000) + 's' + (coverName ? ' （带封面）' : ''));
    try { fs.unlinkSync(outTmp); } catch (e) { }
    try { fs.unlinkSync(tmpIn); } catch (e) { }
  }
  /* 全部转完再写 feed.json：只改这几条的视频/封面字段，别盖掉别人的点赞评论 */
  const cfg2 = JSON.parse(fs.readFileSync(F, 'utf8'));
  let touched = 0;
  const apply = (arr) => (arr || []).forEach((it) => {
    const c = changed.get(it.id);
    if (!c) return;
    it.video = c.video;
    if (c.cover && String(it.cover || '').indexOf('/uploads/') !== 0) it.cover = c.cover;
    touched += 1;
  });
  apply(cfg2.posts); apply(cfg2.items);
  fs.writeFileSync(F + '.tmp', JSON.stringify(cfg2, null, 2));
  fs.renameSync(F + '.tmp', F);
  log('完成：转码 ' + done + ' 条，跳过 ' + skipped + ' 条，失败 ' + failed + ' 条，省下 '
    + (saved/1048576).toFixed(1) + 'MB，更新 ' + touched + ' 条记录');
})();
