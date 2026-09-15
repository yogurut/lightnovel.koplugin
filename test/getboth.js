// 轻书架字体加密 —— 抓取同一请求的 Content + Font，并下载配套字体
//
// 用法：
//   LN_EMAIL=you@example.com LN_PASSWORD=yourpass node test/getboth.js [bookId] [sortNum]
//
// 输出：
//   /tmp/ln-pair.woff2   混淆字体（浏览器用）
//   /tmp/ln-pair.ttf     同一字体（KOReader 用，cmap 与 woff2 一致）
//   /tmp/ln-chapter.json 章节信息
//
// 依赖：
//   npm i @microsoft/signalr @microsoft/signalr-protocol-msgpack
const signalR = require('@microsoft/signalr');
const { MessagePackHubProtocol } = require('@microsoft/signalr-protocol-msgpack');
const crypto = require('crypto');
const zlib = require('zlib');
const fs = require('fs');

const API = process.env.LN_API || 'https://api.lightnovel.life';
const EMAIL = process.env.LN_EMAIL;
const PASSWORD = process.env.LN_PASSWORD;
const BOOK_ID = Number(process.argv[2] || 20287);
const SORT_NUM = Number(process.argv[3] || 1);

if (!EMAIL || !PASSWORD) {
  console.error('请设置 LN_EMAIL / LN_PASSWORD 环境变量');
  process.exit(1);
}

// SignalR 的 Response 可能是 gzip 压缩的二进制
function unwrap(v) {
  if (v instanceof Uint8Array || Buffer.isBuffer(v)) {
    try { return JSON.parse(zlib.gunzipSync(v).toString()); } catch {}
    try { return JSON.parse(Buffer.from(v).toString()); } catch {}
    return Buffer.from(v).toString().slice(0, 300);
  }
  return v;
}

(async () => {
  // 1. 登录（密码 SHA-256）
  const lr = await fetch(`${API}/api/user/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-id': 'test_' + Date.now() },
    body: JSON.stringify({
      email: EMAIL,
      password: crypto.createHash('sha256').update(PASSWORD).digest('hex'),
    }),
  });
  const token = (await lr.json()).Response.Token;
  console.log('✅ 登录成功');

  // 2. 连 Hub
  const conn = new signalR.HubConnectionBuilder()
    .withUrl(`${API}/hub/api`, { accessTokenFactory: () => token })
    .withHubProtocol(new MessagePackHubProtocol())
    .build();
  await conn.start();
  const call = (n, ...a) => conn.invoke(n, ...a, { UseGzip: false });
  console.log('✅ Hub 已连接');

  // 3. 拉章节（关键：Content 与 Font 必须来自同一次请求）
  const res = unwrap((await call('GetNovelContent', { Bid: BOOK_ID, SortNum: SORT_NUM })).Response);
  const ch = res.Chapter;

  // 明文标题来自 GetBookInfo，可用于校对
  const info = unwrap((await call('GetBookInfo', { Id: BOOK_ID })).Response);
  const meta = info.Book.Chapters.find(c => c.SortNum === SORT_NUM);

  const firstP = (ch.Content || '').match(/<p[^>]*>([^<]{2,80})<\/p>/);

  console.log('\n=== 章节信息 ===');
  console.log('Font        :', ch.Font);
  console.log('标题(明文)  :', meta ? meta.Title : ch.Title);
  console.log('标题(密文)  :', firstP ? firstP[1].trim() : '—');

  fs.writeFileSync('/tmp/ln-chapter.json', JSON.stringify({
    bookId: BOOK_ID, sortNum: SORT_NUM,
    font: ch.Font, titlePlain: meta ? meta.Title : ch.Title,
    titleCipher: firstP ? firstP[1].trim() : null,
    contentLength: (ch.Content || '').length,
  }, null, 2));

  // 4. 下载配套字体（ttf + woff2）
  if (ch.Font) {
    const hash = ch.Font.split('/').pop().replace(/\.(woff2|ttf)$/, '');
    for (const ext of ['woff2', 'ttf']) {
      const r = await fetch(`${API}/font/${hash}.${ext}`);
      if (r.ok) {
        const buf = Buffer.from(await r.arrayBuffer());
        fs.writeFileSync(`/tmp/ln-pair.${ext}`, buf);
        console.log(`✅ /tmp/ln-pair.${ext}  ${buf.length} bytes`);
      } else {
        console.log(`❌ ${ext}: HTTP ${r.status}`);
      }
    }
  }

  await conn.stop();
})().catch(e => { console.error('❌', e.message); process.exit(1); });
