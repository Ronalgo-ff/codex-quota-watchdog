#!/usr/bin/env node
/*
 * 读取 DSH 会话的上下文占用率。
 *
 * 为什么需要单独一个脚本：DSH 的会话日志是「多帧 zstd」append 格式，
 * 一个文件里有几百上千个独立的 zstd 帧。PowerShell 没法直接解，Node 的
 * 一次性解压也只处理第一帧，必须逐帧解。
 *
 * 用法：
 *   node session-context.js <会话文件路径> [帧数=12]
 *   node session-context.js --list               列出所有会话
 *
 * 输出：一行 JSON
 *   {"ok":true,"sessionId":"...","used":354039,"window":1000000,"percent":35.4,"messages":200}
 */
'use strict';
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const ZSTD_MAGIC = Buffer.from([0x28, 0xB5, 0x2F, 0xFD]);
const DEFAULT_FRAMES = 12;

function findFrames(buf) {
  const pos = [];
  let i = 0;
  while ((i = buf.indexOf(ZSTD_MAGIC, i)) !== -1) {
    pos.push(i);
    i += 4;
  }
  return pos;
}

/** 只解压最后 count 个帧：够拿到最新的 usage 就行，避免解整个文件 */
function decompressTail(buf, count) {
  const pos = findFrames(buf);
  if (pos.length === 0) return { text: '', frames: 0 };
  const from = Math.max(0, pos.length - count);
  const parts = [];
  for (let k = from; k < pos.length; k++) {
    const start = pos[k];
    const end = k + 1 < pos.length ? pos[k + 1] : buf.length;
    try {
      parts.push(zlib.zstdDecompressSync(buf.subarray(start, end)));
    } catch {
      /* 损坏的帧跳过 */
    }
  }
  return { text: Buffer.concat(parts).toString('utf8'), frames: pos.length };
}

/** 解压全部帧：统计消息数等需要完整数据时才用 */
function decompressAll(buf) {
  const pos = findFrames(buf);
  const parts = [];
  for (let k = 0; k < pos.length; k++) {
    const start = pos[k];
    const end = k + 1 < pos.length ? pos[k + 1] : buf.length;
    try {
      parts.push(zlib.zstdDecompressSync(buf.subarray(start, end)));
    } catch {
      /* 忽略 */
    }
  }
  return Buffer.concat(parts).toString('utf8');
}

function parseLines(text) {
  const out = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line));
    } catch {
      /* 截断的行忽略 */
    }
  }
  return out;
}

function readSession(file, frameCount) {
  if (!fs.existsSync(file)) {
    return { ok: false, error: 'session file not found', file };
  }
  const buf = fs.readFileSync(file);

  // 上下文窗口：用 request/context 事件
  let window = null;
  const allObjs = parseLines(decompressAll(buf));
  for (const o of allObjs) {
    if (o.type === 'request/context' && o.data && o.data.contextWindow) {
      window = o.data.contextWindow;
    }
  }

  // 最新占用：用最后一条带 usage 的 assistant/message
  const tailObjs = parseLines(decompressTail(buf, frameCount).text);
  let usage = null;
  for (const o of tailObjs) {
    if (o.type === 'assistant/message' && o.data && o.data.usage) usage = o.data.usage;
  }
  // 尾部帧不够时回退到全量
  if (!usage) {
    for (const o of allObjs) {
      if (o.type === 'assistant/message' && o.data && o.data.usage) usage = o.data.usage;
    }
  }

  const assistantCount = allObjs.filter(
    (o) => o.type === 'assistant/message'
  ).length;
  const sessionObj = allObjs.find((o) => o.type === 'session');

  const used = usage ? usage.totalTokens : null;
  const percent = used && window ? Math.round((used / window) * 1000) / 10 : null;

  return {
    ok: used !== null && window !== null,
    file,
    sessionId: path.basename(path.dirname(file)),
    used,
    window,
    percent,
    messages: assistantCount,
    usage,
  };
}

/** 列出 DSH_HOME 下所有会话 */
function listSessions(home) {
  const root = path.join(home, 'sessions');
  const out = [];
  if (!fs.existsSync(root)) return out;
  for (const proj of fs.readdirSync(root)) {
    const projDir = path.join(root, proj);
    if (!fs.statSync(projDir).isDirectory()) continue;
    for (const sess of fs.readdirSync(projDir)) {
      const sessDir = path.join(projDir, sess);
      if (!fs.statSync(sessDir).isDirectory()) continue;
      const file = path.join(sessDir, 'session.v4.jsonl.zstd');
      if (!fs.existsSync(file)) continue;
      const st = fs.statSync(file);
      out.push({
        sessionId: sess,
        project: proj,
        file,
        mtime: st.mtime.toISOString(),
        sizeKB: Math.round(st.size / 1024),
      });
    }
  }
  out.sort((a, b) => (a.mtime < b.mtime ? 1 : -1));
  return out;
}

function main() {
  const args = process.argv.slice(2);
  if (args[0] === '--list') {
    const home = args[1] || process.env.DSH_HOME || 'D:\\app date\\dsh';
    process.stdout.write(JSON.stringify({ ok: true, home, sessions: listSessions(home) }));
    return;
  }
  const file = args[0];
  const frames = args[1] ? parseInt(args[1], 10) : DEFAULT_FRAMES;
  if (!file) {
    process.stdout.write(
      JSON.stringify({ ok: false, error: 'usage: session-context.js <file> [frames] | --list [home]' })
    );
    process.exitCode = 2;
    return;
  }
  try {
    process.stdout.write(JSON.stringify(readSession(file, frames)));
  } catch (error) {
    process.stdout.write(JSON.stringify({ ok: false, error: String(error && error.message) }));
    process.exitCode = 1;
  }
}

main();
