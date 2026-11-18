// Compare a stock Android boot image against its Magisk-patched copy.
// Verifies: header magic, kernel bytes identical, ramdisk changed, magisk present in ramdisk.
const fs = require("fs");
const zlib = require("zlib");
const c = require("crypto");

const h = (b) => c.createHash("sha256").update(b).digest("hex");
const u32 = (b, o) => b.readUInt32LE(o);
const hx = (b, o, n) => b.subarray(o, o + n).toString("hex");

function parse(p) {
  const f = fs.readFileSync(p);
  if (f.toString("latin1", 0, 8) !== "ANDROID!") throw new Error(p + " 不是 Android boot image");
  const o = {
    file: p,
    f,
    size: f.length,
    kernel: u32(f, 8),
    ramdisk: u32(f, 16),
    second: u32(f, 24),
    page: u32(f, 36),
    header: u32(f, 40),
    os: u32(f, 44),
    name: f.toString("latin1", 64, 96).replace(/\0.*$/, ""),
    cmdline: f.toString("latin1", 512, 1024).replace(/\0.*$/, ""),
  };
  const pg = o.page || 2048;
  const al = (n) => Math.ceil(n / pg) * pg;
  const head = Math.max(o.header, pg);
  o.koff = al(head);
  o.roff = o.koff + al(o.kernel);
  o.kb = f.subarray(o.koff, o.koff + o.kernel);
  o.rb = f.subarray(o.roff, o.roff + o.ramdisk);
  o.khash = h(o.kb);
  o.rhash = h(o.rb);
  o.kmagic = o.kb.subarray(0, 8).toString("hex");
  o.rmagic = o.rb.subarray(0, 4).toString("hex");
  return o;
}

function cpioList(buf) {
  let b = buf;
  if (b[0] === 0x1f && b[1] === 0x8b) b = zlib.gunzipSync(b);
  const entries = [];
  let q = 0;
  while (b.toString("latin1", q, q + 6) === "070701") {
    const hex = (o, n) => parseInt(b.toString("latin1", q + o, q + o + n), 16);
    const filesize = hex(54, 8);
    const namesize = hex(94, 8);
    const name = b.toString("latin1", q + 110, q + 110 + namesize - 1);
    entries.push({ name, filesize });
    q = Math.ceil((q + 110 + namesize) / 4) * 4 + ((filesize + 3) & ~3);
    if (name === "TRAILER!!!") break;
  }
  return { entries, bytes: b.length };
}

const [stockP, patP] = process.argv.slice(2);
const a = parse(stockP);
const b = parse(patP);
const rows = [
  ["文件", `${a.file} → ${b.file}`],
  ["长度", `${a.size} → ${b.size} (${b.size - a.size >= 0 ? "+" : ""}${b.size - a.size})`],
  ["kernel 长度", `${a.kernel} → ${b.kernel} ${a.kernel === b.kernel ? "★ 未改" : "⚠ 变了"}`],
  ["kernel SHA256", a.khash === b.khash ? "★ 与原厂逐字节相同" : `⚠ 不同 ${a.khash.slice(0, 12)}… → ${b.khash.slice(0, 12)}…`],
  ["kernel 压缩头", `${a.kmagic} → ${b.kmagic}`],
  ["ramdisk 长度", `${a.ramdisk} → ${b.ramdisk} (+${b.ramdisk - a.ramdisk})`],
  ["ramdisk SHA256", a.rhash === b.rhash ? "⚠ 与原厂相同(没打进去!)" : "★ 已改动"],
  ["ramdisk 压缩头", `${a.rmagic} → ${b.rmagic} ${b.rmagic === "1f8b0800" ? "(gzip)" : ""}`],
  ["page size", `${a.page} → ${b.page}`],
  ["os_version", `${hx(a.f, 44, 4)} → ${hx(b.f, 44, 4)}`],
  ["name", `${a.name} → ${b.name}`],
  ["cmdline 相同", a.cmdline === b.cmdline ? "★ 是" : `⚠ 否\n  原厂: ${a.cmdline}\n  修补: ${b.cmdline}`],
];
for (const [k, v] of rows) console.log(`${k.padEnd(16)} ${v}`);

const r = cpioList(b.rb);
console.log(`\n修补后 ramdisk 解包 ${r.bytes} B, ${r.entries.length} 个条目`);
const mk = r.entries.filter((e) => /magisk|overlay|customiz|module|resetprop|init\.rc/.test(e.name));
console.log("命中 Magisk 相关条目:");
for (const e of mk.slice(0, 14)) console.log(`  ${e.name}  (${e.filesize} B)`);
const s = cpioList(a.rb);
console.log(`\n原厂 ramdisk 解包 ${s.bytes} B, ${s.entries.length} 个条目`);
console.log(`原厂条目 ${s.entries.length} vs 修补后 ${r.entries.length} → 新增 ${r.entries.length - s.entries.length} 个`);