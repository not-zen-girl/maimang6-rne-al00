// Identify a raw filesystem image and mine it for property / VINTF evidence.
// node tools/img_probe.js <img> [needle ...]
const fs = require('fs');

const file = process.argv[2];
const needles = process.argv.slice(3);
if (!file) {
  console.error('usage: node img_probe.js <img> [needle...]');
  process.exit(2);
}

const fd = fs.openSync(file, 'r');
const size = fs.fstatSync(fd).size;

function readAt(off, len) {
  const b = Buffer.alloc(len);
  const got = fs.readSync(fd, b, 0, len, off);
  return b.subarray(0, got);
}

// --- filesystem identity -------------------------------------------------
const head = readAt(0, Math.min(65536, size));
const u16 = (b, o) => b.readUInt16LE(o);
const u32 = (b, o) => b.readUInt32LE(o);
const id = {};
if (head.subarray(0, 4).equals(Buffer.from([0xed, 0x26, 0xff, 0x3a]))) id.sparseExt4 = true;
if (u16(head, 0x38) === 0xef53) id.ext4At0 = { rev: u32(head, 0x3c) >>> 16, blocks: u32(head, 4), blockLog: u32(head, 24), mtime: new Date(u32(head, 20) * 1000).toISOString().slice(0, 10) };
if (head.subarray(0, 8).toString('latin1') === 'ANDROID!') id.bootHeader = true;
if (head.subarray(0, 16).toString('latin1').startsWith('OGGAVRO')) id.erofs = true;
if (head.subarray(0x438, 0x440).toString('latin1') === 'AvsB') id.androidVsMeta = true;
// superblock may live at 1024 for a wrapped image, or after a 4096-byte packing prefix
for (const base of [0x1000, 0x8000]) {
  const b = readAt(base, 2048);
  if (b.length > 0x400 && u16(b, 0x38) === 0xef53) id['ext4At' + base.toString(16)] = { blocks: u32(b, 4), blockLog: u32(b, 24), mtime: new Date(u32(b, 20) * 1000).toISOString().slice(0, 10) };
}
// partition-table image
if (head.subarray(0x200, 0x208).toString('latin1') === 'EFI PART') id.gptPrimary = true;
console.log(file.split(/[\\/]/).pop(), size.toLocaleString(), 'bytes', JSON.stringify(id));

// --- entropy over a mid-file sample (encrypted payloads score ~7.99) ------
const sOff = Math.floor(size / 2), sLen = Math.min(4 << 20, size - sOff);
const freq = new Float64Array(256);
const s = readAt(sOff, sLen);
for (const c of s) freq[c]++;
let H = 0;
for (let i = 0; i < 256; i++) if (freq[i]) { const p = freq[i] / s.length; H -= p * Math.log2(p); }
console.log('entropy of', (sLen >> 20) + ' MiB mid-file sample:', H.toFixed(2), H > 7.9 ? '=> ENCRYPTED-LOOKING' : H > 7.2 ? '=> compressed' : '=> structured/plain-ish');

if (!needles.length) { fs.closeSync(fd); return; }

// --- streamed needle scan ------------------------------------------------
const CHUNK = 8 << 20, OVERLAP = 512;
const hits = Object.fromEntries(needles.map((n) => [n, 0]));
const buf = Buffer.alloc(CHUNK);
let pos = 0, prev = Buffer.alloc(0);
const shown = {};
while (pos < size) {
  const len = fs.readSync(fd, buf, 0, Math.min(CHUNK, size - pos), pos);
  const win = Buffer.concat([prev, buf.subarray(0, len)]);
  for (const n of needles) {
    const nb = Buffer.from(n, 'latin1');
    let from = 0;
    for (;;) {
      const i = win.indexOf(nb, from);
      if (i < 0) break;
      hits[n]++;
      const absOff = pos - prev.length + i;
      if ((shown[n] || 0) < 2) {
        shown[n] = (shown[n] || 0) + 1;
        const ctx = readAt(Math.max(0, absOff - 120), Math.min(560, n.length + 400));
        const txt = ctx.toString('latin1').replace(/[^\x20-\x7e\n]/g, '·').replace(/\n{3,}/g, '\n');
        console.log(`\n### ${n}  hit#${hits[n]} @ 0x${absOff.toString(16)}`);
        console.log(txt.trim());
      }
      from = i + nb.length;
      if (hits[n] > 4000) break;
    }
  }
  prev = buf.subarray(Math.max(0, len - OVERLAP), len);
  pos += len;
  if (len <= 0) break;
}
fs.closeSync(fd);
console.log('\n=== hit counts ===');
for (const [n, c] of Object.entries(hits)) console.log(String(c).padStart(7), n);