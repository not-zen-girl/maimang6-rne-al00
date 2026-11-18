// Identify the real container/filesystem format of every extracted image.
// node tools/magic_scan.js <dir>
const fs = require('fs');
const path = require('path');

const dir = process.argv[2] || '.';
const ext4At = (b, base) => b.length > base + 0x438 + 2 && b.readUInt16LE(base + 0x38) === 0xef53;

function classify(f, head) {
  const m = [];
  const u32 = (o) => (head.length >= o + 4 ? head.readUInt32LE(o) : 0);
  const txt = (o, n) => (head.length >= o + n ? head.subarray(o, o + n).toString('latin1') : '');
  if (txt(0, 4) === 'hsqs') m.push('squashfs');
  if (head.subarray(0, 4).equals(Buffer.from([0x3a, 0xff, 0x26, 0xed]))) m.push('sparse-ext4');
  if (u32(0x400) === 0xf2f5ae16) m.push('f2fs');
  if (u32(0x400) === 0xe0f5e1e2) m.push('erofs');
  if (head.subarray(0, 8).toString('latin1') === 'ANDROID!') m.push('boot-image');
  if (head.subarray(0x200, 0x208).toString('latin1') === 'EFI PART') m.push('GPT');
  if (head.subarray(0, 6).toString('latin1').startsWith('\x1f\x8b\x08')) m.push('gzip');
  if (head.subarray(0, 6).toString('latin1').startsWith('BZh')) m.push('bzip2');
  if (head.subarray(0, 4).toString('latin1') === '\x28\xb5\x2f\xfd') m.push('zstd');
  if (head.subarray(0, 6).toString('latin1') === '7z\xbc\xaf\x27\x1c') m.push('7z');
  if (head.subarray(0, 4).toString('latin1') === 'OVR2' || head.subarray(0, 4).toString('latin1') === 'OVRM') m.push('android-ota');
  if (head.subarray(0x1000, 0x1008).toString('latin1') === 'ANDROID!') m.push('boot-image@0x1000');
  for (const base of [0, 0x1000, 0x8000, 0x10000, 0x20000, 0x40000]) {
    if (ext4At(head, base)) m.push(base === 0 ? 'ext4' : `ext4@0x${base.toString(16)}`);
  }
  return m.length ? [...new Set(m)].join('+') : '?';
}

const rows = [];
for (const name of fs.readdirSync(dir)) {
  if (!/\.img$/i.test(name)) continue;
  const p = path.join(dir, name);
  const st = fs.statSync(p);
  const fd = fs.openSync(p, 'r');
  const head = Buffer.alloc(Math.min(0x41000, st.size));
  const got = fs.readSync(fd, head, 0, head.length, 0);
  fs.closeSync(fd);
  rows.push([name, st.size, classify(p, head.subarray(0, got))]);
}
rows.sort((a, b) => b[1] - a[1]);
console.log('size'.padStart(15), 'format'.padEnd(24), 'image');
for (const [n, s, f] of rows) console.log(s.toLocaleString().padStart(15), f.padEnd(24), n);