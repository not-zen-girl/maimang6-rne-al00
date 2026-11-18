// Entropy profile over several offsets, for telling opaque-but-official blobs from real corruption.
// node tools/entropy_scan.js f1.img f2.img ...
const fs = require('fs');

function ent(b) {
  const f = new Float64Array(256);
  for (const c of b) f[c]++;
  let H = 0;
  for (let i = 0; i < 256; i++) if (f[i]) { const p = f[i] / b.length; H -= p * Math.log2(p); }
  return H;
}

for (const p of process.argv.slice(2)) {
  const fd = fs.openSync(p, 'r');
  const size = fs.fstatSync(fd).size;
  const n = Math.min(6, Math.max(1, Math.floor(size / 65536)));
  const hs = [];
  for (let i = 0; i < n; i++) {
    const off = Math.floor(((size - 65536) * i) / Math.max(1, n - 1));
    const b = Buffer.alloc(Math.min(65536, size - off));
    const got = fs.readSync(fd, b, 0, b.length, off);
    hs.push(ent(b.subarray(0, got)));
  }
  fs.closeSync(fd);
  const avg = hs.reduce((a, b) => a + b, 0) / hs.length;
  console.log(`${p.split(/[\\/]/).pop().padEnd(24)} ${size.toLocaleString().padStart(14)}  avg ${avg.toFixed(2)}  min ${Math.min(...hs).toFixed(2)}  max ${Math.max(...hs).toFixed(2)}  ${avg > 7.9 ? 'OPAQUE(压缩/加密)' : 'structured'}`);
}