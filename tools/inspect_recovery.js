const fs = require("fs");
const zlib = require("zlib");

const al = (n, p) => Math.ceil(n / p) * p;

function u32(b, o) { return b.readUInt32LE(o); }

function cpioList(buf) {
  let b = buf;
  const m0 = b[0], m1 = b[1];
  if (m0 === 0x1f && m1 === 0x8b) b = zlib.gunzipSync(b);
  const out = [];
  let q = 0;
  while (b.toString("latin1", q, q + 6) === "070701" || b.toString("latin1", q, q + 6) === "070702") {
    const hex = (o, n) => parseInt(b.toString("latin1", q + o, q + o + n), 16);
    const filesize = hex(54, 8);
    const namesize = hex(94, 8);
    const mode = hex(12, 8);
    const name = b.toString("latin1", q + 110, q + 110 + namesize - 1);
    out.push({ name, size: filesize, dir: !!(mode & 0x4000), exec: (mode & 0x3f) >= 0x49 });
    q = al(q + 110 + namesize, 4) + al(filesize, 4);
    if (name === "TRAILER!!!") break;
    if (out.length > 40000) break;
  }
  return { entries: out, decompressed: b.length, rawIsGzip: m0 === 0x1f };
}

function scanStrings(buf, needles) {
  const hits = {};
  for (const n of needles) {
    const idx = buf.indexOf(Buffer.from(n, "latin1"));
    if (idx >= 0) hits[n] = "0x" + idx.toString(16);
  }
  return hits;
}

for (const file of process.argv.slice(2)) {
  const f = fs.readFileSync(file);
  console.log("\n===== " + file + "  size=" + f.length + "  sha256(head)= " + require("crypto").createHash("sha256").update(f).digest("hex").slice(0, 16));
  const magic = f.toString("latin1", 0, 8);
  console.log("magic@0 =", magic, magic === "ANDROID!" ? "OK(android boot image)" : "<- NOT a boot/recovery image header");
  if (magic !== "ANDROID!") continue;

  const kernel = u32(f, 40), ramdisk = u32(f, 44), second = u32(f, 48);
  const pagesize = u32(f, 36) || 2048;
  const headerVersion = u32(f, 48 + 32); // v4 header at offset 80 is header_version (v3+)
  const hv = u32(f, 80);
  const name = f.toString("latin1", 8, 24).replace(/\0.*$/, "");
  const cmdline = f.toString("latin1", 512, 512 + 512).split("\0")[0];
  console.log("name=\"" + name + "\" pagesize=" + pagesize + " header_version=" + hv);
  console.log("kernel=" + kernel + " ramdisk=" + ramdisk + " second(dtb?)=" + second + " tags_addr=0x" + u32(f, 32).toString(16));
  console.log("cmdline=" + cmdline.slice(0, 220));

  let off = al(Math.max(kernel === 0 ? 0 : al(kernel, pagesize) , 1) + pagesize, pagesize);
  const rd = f.subarray(pagesize + al(kernel, pagesize), pagesize + al(kernel, pagesize) + al(ramdisk, pagesize));
  let info = "ramdisk head bytes: " + Buffer.from(rd.subarray(0, 8)).toString("hex");
  try {
    const c = cpioList(rd);
    const names = c.entries.map(e => e.name);
    const interesting = names.filter(n => /twrp|recovery|rescue|init$|init\.rc|fstab|default\.txt|healthd|magisk/i.test(n));
    console.log("ramdisk decompressed=" + c.decompressed + " entries=" + c.entries.length + " gzip=" + c.rawIsGzip);
    console.log("  notable entries: " + interesting.slice(0, 25).join(", "));
    const dec = c.entries.length ? null : null;
  } catch (e) {
    console.log("ramdisk parse failed: " + e.message);
  }
  console.log(info);

  const compat = scanStrings(f, ["hisilicon,hi6250", "hi6250", "hi6250,htop", "RNE-AL00", "HWRNE", "kirin65x", "kirin620", "hi3660", "hi3751v", "hi6250,mdio", "q2s"]);
  console.log("board/soc markers found in whole image: " + JSON.stringify(compat));

  const twrpVer = [];
  const re = /twrp[ -_]?version[ =]*[0-9][0-9.]+|TWRP-3\.[0-9][0-9.]+|twmpath_chk|twrp 3\.[0-9][0-9.]*/gi;
  const s = f.toString("latin1");
  let m; let n = 0;
  while ((m = re.exec(s)) && n < 6) { twrpVer.push(m[0].replace(/[^\x20-\x7e]/g, ".").slice(0, 60)); n++; }
  console.log("TWRP version-ish strings: " + (twrpVer.length ? twrpVer.join(" | ") : "(none in plaintext - ramdisk is compressed)"));

  const dts = Buffer.from(f).indexOf(Buffer.from("d00dfeed", "hex"));
  console.log("first FDT blob (d00dfeed) at: " + (dts >= 0 ? "0x" + dts.toString(16) : "none") + " ; total FDT count=" + ((s.match(/\xd0\x0d\xfe\xed/g) || []).length));
}