// Parse a primary GPT dump (Huawei efi.img, or `dd bs=512 count=34` off a device) and diff two tables.
// node tools/gpt_parse.js <a.img> [b.img]
const fs = require('fs');

function parse(file, lbaSize = 512) {
  const buf = fs.readFileSync(file);
  const hOff = buf.subarray(0x200, 0x208).toString('latin1') === 'EFI PART' ? 0x200 : buf.indexOf('EFI PART', 0, 'latin1');
  if (hOff < 0) throw new Error(`${file}: no EFI PART signature in the first ${buf.length} bytes`);
  const u32 = (o) => buf.readUInt32LE(o);
  const u64 = (o) => Number(buf.readBigUInt64LE(o));
  const guid = (o) => {
    const b = buf.subarray(o, o + 16);
    const h = b.toString('hex').match(/../g);
    return `${h.slice(0, 4).reverse().join('')}-${h.slice(4, 6).reverse().join('')}-${h.slice(6, 8).reverse().join('')}-${h.slice(8, 10).join('')}-${h.slice(10).join('')}`.toUpperCase();
  };
  const num = u32(hOff + 0x50);
  const esz = u32(hOff + 0x54);
  const eBase = u64(hOff + 0x48) * lbaSize;
  const rows = [];
  for (let i = 0; i < num; i++) {
    const o = eBase + i * esz;
    if (o + esz > buf.length) break;
    const first = u64(o + 0x20), last = u64(o + 0x28);
    if (first === 0 && last === 0) continue;
    const raw = buf.subarray(o + 0x38, o + 0x38 + 72);
    let name = '';
    for (let c = 0; c < 72; c += 2) {
      const ch = raw.readUInt16LE(c);
      if (!ch) break;
      name += String.fromCharCode(ch);
    }
    rows.push({ slot: i, name, first, last, mb: ((last - first + 1) * lbaSize) / (1024 * 1024), type: guid(o) });
  }
  return {
    file,
    header: { revision: u32(hOff + 8), entries: num, entrySize: esz, myLba: u64(hOff + 0x18), altLba: u64(hOff + 0x20), firstUsable: u64(hOff + 0x28), lastUsable: u64(hOff + 0x30), diskGiB: ((u64(hOff + 0x30) - u64(hOff + 0x28) + 2) * lbaSize) / 1024 ** 3 },
    rows,
  };
}

const [a, b] = [process.argv[2], process.argv[3]];
if (!a) {
  console.error('usage: node gpt_parse.js <gpt.img> [other.gpt.img]');
  process.exit(2);
}
const A = parse(a);
console.log(A.file, JSON.stringify(A.header));
const w = Math.max(...A.rows.map((r) => r.name.length), 8);
for (const r of A.rows) console.log(`p${String(r.slot + 1).padStart(2)}  ${r.name.padEnd(w)}  ${String(r.mb.toFixed(1)).padStart(9)} MB  LBA ${r.first}..${r.last}`);

if (b) {
  const B = parse(b);
  const byName = (t) => Object.fromEntries(t.rows.map((r) => [r.name, r]));
  const x = byName(A), y = byName(B);
  console.log(`\n=== diff  ${A.rows.length} → ${B.rows.length} 分区 ===`);
  for (const n of new Set([...Object.keys(x), ...Object.keys(y)])) {
    const p = x[n], q = y[n];
    if (!p) console.log(`  +新增  ${n.padEnd(w)}  ${(q.mb.toFixed(1) + ' MB').padStart(10)}`);
    else if (!q) console.log(`  -消失  ${n.padEnd(w)}  ${(p.mb.toFixed(1) + ' MB').padStart(10)}`);
    else if (Math.abs(p.mb - q.mb) > 0.05) console.log(`  ~改小/大 ${n.padEnd(w)}  ${p.mb.toFixed(1)} → ${q.mb.toFixed(1)} MB`);
  }
}