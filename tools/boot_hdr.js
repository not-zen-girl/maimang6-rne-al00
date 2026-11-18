#!/usr/bin/env node
// Decode the Android boot-image header at a given offset of a partition image.
// Only reports fields that are actually inside the file.
const fs = require("fs");

const PAGE = 4096;
function u32(b, o) {
  return o + 4 <= b.length ? b.readUInt32LE(o) : undefined;
}
function name(b, o, n) {
  const s = b.subarray(o, Math.min(o + n, b.length));
  const z = s.indexOf(0);
  return (z < 0 ? s : s.subarray(0, z)).toString("utf8");
}
function head(b, o, n) {
  return Buffer.from(b.subarray(o, Math.min(o + n, b.length))).toString("hex").replace(/(..)/g, "$1 ");
}

for (const arg of process.argv.slice(2)) {
  const m = /^(.*?):(\d+)$/.exec(arg);
  const file = m ? m[1] : arg;
  const off = m ? Number(m[2]) : 0;
  const fd = fs.openSync(file, "r");
  const size = fs.fstatSync(fd).size;
  const buf = Buffer.alloc(Math.min(1024, Math.max(0, size - off)));
  fs.readSync(fd, buf, 0, buf.length, off);
  const magic = buf.subarray(0, 8).toString("latin1");
  console.log(`== ${file} @${off} filebytes=${size}`);
  console.log(`   head[48] ${head(buf, 0, 48)}`);
  if (magic !== "ANDROID!") {
    console.log(`   NOT an android boot header (magic=${JSON.stringify(magic)})`);
    fs.closeSync(fd);
    continue;
  }
  const k = u32(buf, 8), ka = u32(buf, 12);
  const r = u32(buf, 16), ra = u32(buf, 20);
  const s = u32(buf, 24), sa = u32(buf, 28);
  const tags = u32(buf, 32), pgsz = u32(buf, 36);
  const hw = name(buf, 40, 16), cmd = name(buf, 512, 512).trim();
  const hv = u32(buf, 40);
  const kpages = pgsz && pgsz <= 0x40000 ? Math.ceil((k || 0) / pgsz) : 0;
  const rpages = pgsz && pgsz <= 0x40000 ? Math.ceil((r || 0) / pgsz) : 0;
  const kStart = off + (kpages || 1) * (pgsz || PAGE);
  const rStart = off + (kpages + rpages + 1) * (pgsz || PAGE);
  const peek = (o) => {
    if (!Number.isFinite(o) || o >= size) return "n/a";
    const b2 = Buffer.alloc(4);
    fs.readSync(fd, b2, 0, 4, o);
    return b2.toString("hex");
  };
  console.log(`   kernel  size=${k} addr=0x${(ka >>> 0).toString(16)} start=${kStart} first4=${peek(kStart)}`);
  console.log(`   ramdisk size=${r} addr=0x${(ra >>> 0).toString(16)} start=${rStart} first4=${peek(rStart)}`);
  console.log(`   second  size=${s} addr=0x${(sa >>> 0).toString(16)}`);
  console.log(`   tags=0x${(tags >>> 0).toString(16)} page_size=${pgsz} header_version=${hv} hw=${JSON.stringify(hw)}`);
  console.log(`   cmdline=${JSON.stringify(cmd.slice(0, 400))}`);
  fs.closeSync(fd);
}