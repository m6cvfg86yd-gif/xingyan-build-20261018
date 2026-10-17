'use strict';

/**
 * 极简 WebSocket 服务端实现（RFC 6455），零依赖。
 * 只实现聊天场景需要的能力：握手、文本帧、分片、ping/pong、close。
 */

const crypto = require('crypto');

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const MAX_FRAME = 512 * 1024;             // 单帧上限 512KB（聊天文字上限才 4000 字，图/音都是走 HTTP 上传）
/* 累积缓冲上限：有人故意发一半（声明 20MB 只发一半）时，缓冲会一直涨，
   几百条连接一起这么干能把服务拖死。超过就直接断开。 */
const MAX_BUFFER = 512 * 1024;            // 累积缓冲上限 512KB

function acceptKey(key) {
  return crypto.createHash('sha1').update(key + GUID).digest('base64');
}

function encodeFrame(opcode, payload) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload), 'utf8');
  const len = data.length;
  let header;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[1] = len;
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  header[0] = 0x80 | opcode;
  return Buffer.concat([header, data]);
}

/**
 * 从缓冲区里尽量多地解析出完整帧，返回帧数组和剩余字节。
 * 支持客户端掩码、16/64 位长度。
 */
function decodeFrames(buffer) {
  const frames = [];
  let offset = 0;
  while (offset + 2 <= buffer.length) {
    const b0 = buffer[offset];
    const b1 = buffer[offset + 1];
    const fin = (b0 & 0x80) !== 0;
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    let len = b1 & 0x7f;
    let p = offset + 2;

    if (len === 126) {
      if (p + 2 > buffer.length) break;
      len = buffer.readUInt16BE(p);
      p += 2;
    } else if (len === 127) {
      if (p + 8 > buffer.length) break;
      const big = buffer.readBigUInt64BE(p);
      len = big > BigInt(MAX_FRAME) ? -1 : Number(big);
      p += 8;
    }
    if (len < 0) { offset = buffer.length; break; }

    let mask = null;
    if (masked) {
      if (p + 4 > buffer.length) break;
      mask = buffer.subarray(p, p + 4);
      p += 4;
    }
    if (p + len > buffer.length) break;

    const payload = Buffer.from(buffer.subarray(p, p + len));
    if (mask) {
      for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i & 3];
    }
    offset = p + len;
    frames.push({ fin, opcode, payload });
  }
  return { frames, rest: buffer.subarray(offset) };
}

function sendText(socket, text) {
  if (!socket || socket.destroyed) return false;
  try {
    socket.write(encodeFrame(0x1, Buffer.from(text, 'utf8')));
    return true;
  } catch (err) {
    return false;
  }
}

function attach(socket, { onMessage, onClose }) {
  let buffer = Buffer.alloc(0);
  let fragments = [];
  let fragmentOpcode = 0;

  socket.on('data', (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    /* 缓冲涨到上限还没凑齐一帧 → 判定为恶意（半帧攻击），直接断开，别在这耗内存和 CPU */
    if (buffer.length > MAX_BUFFER) {
      buffer = Buffer.alloc(0);
      socket.destroy();
      return;
    }
    const { frames, rest } = decodeFrames(buffer);
    buffer = rest;

    for (const frame of frames) {
      if (frame.payload && frame.payload.length > MAX_FRAME) { socket.destroy(); return; }
      if (frame.opcode === 0x8) { socket.end(); return; }
      if (frame.opcode === 0x9) { socket.write(encodeFrame(0xA, frame.payload)); continue; }
      if (frame.opcode === 0xA) continue;

      if (frame.opcode === 0x0) {
        fragments.push(frame.payload);
        if (frame.fin) {
          const full = Buffer.concat(fragments);
          fragments = [];
          onMessage(full.toString('utf8'), fragmentOpcode);
        }
        continue;
      }

      if (frame.opcode === 0x1 || frame.opcode === 0x2) {
        if (!frame.fin) {
          fragments = [frame.payload];
          fragmentOpcode = frame.opcode;
          continue;
        }
        onMessage(frame.payload.toString('utf8'), frame.opcode);
      }
    }
  });

  const done = () => { if (onClose) onClose(); };
  socket.on('close', done);
  socket.on('end', done);
  socket.on('error', done);
}

module.exports = { acceptKey, encodeFrame, decodeFrames, sendText, attach };
