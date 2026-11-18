const fs = require("fs");
const zlib = require("zlib");
const crypto = require("crypto");

const u32 = (b, o) => b.readUInt32LE(o);
const al = (n, p) => Math.ceil(n / p) * p;

function gunzipAt(buf) {
  if (buf[0] === 0x1f && buf[1] === 0x8b) return zlib.gunzipSync(buf, { finishFlush: 4 });
  return buf;
}

function parts(file) {
  const f = fs.readFileSync(file);
  const page = u32(f, 36) || 2048;
  const ksz = u32(f, 8), rsz = u32(f, 16);
  const koff = page;
  const kernel = gunzipAt(f.subarray(koff, koff + al(ksz, page)));
  const roff = koff + al(ksz, page);
  const ramdisk = gunzipAt(f.subarray(roff, roff + al(rsz, page)));
  return { file, bytes: f.length, ksz, rsz, kernel, ramdisk };
}

function linuxVersion(img) {
  const i = img.indexOf("Linux version");
  return i < 0 ? "(none)" : img.toString("latin1", i, i + 78).replace(/[^\x20-\x7e]/g, ".").trim();
}
function armMagic(img) {
  const hex = [];
  for (const off of [0x0, 0x30, 0x38]) hex.push("0x" + off.toString(16) + "=" + u32(img, off).toString(16));
  return hex.join(" ");
}
function strs(buf, re, limit) {
  const out = new Set();
  const txt = buf.toString("latin1");
  let m;
  const rx = new RegExp(re, "g");
  while ((m = rx.exec(txt)) !== null && out.size < limit) {
    out.add(m[0].replace(/[^\x20-\x7e]/g, "."));
    if (rx.lastIndex > 20000000) break;
  }
  return [...out];
}

const files = ["twrp_rne_emui51.img", "stock_b186/recovery.img", "stock_b186/boot_pure.img"];
const res = {};
for (const file of files) {
  const p = parts(file);
  res[file] = p;
  console.log("\n### " + file + "  bytes=" + p.bytes + " kernel_stored=" + p.ksz + " ramdisk_stored=" + p.rsz);
  console.log("  kernel_decompressed=" + p.kernel.length + "  sha256=" + crypto.createHash("sha256").update(p.kernel).digest("hex").slice(0, 24));
  console.log("  arm64 header: " + armMagic(p.kernel));
  console.log("  " + linuxVersion(p.kernel));
  console.log("  ramdisk_decompressed=" + p.ramdisk.length + " sha256=" + crypto.createHash("sha256").update(p.ramdisk).digest("hex").slice(0, 24));
  const kv = p.kernel.toString("latin1").match(/linux_version_autogen[^\x00]{0,40}|Linux version 4\.1\.18-g[0-9a-f]+/g);
  if (kv) console.log("  kernel build tags: " + [...new Set(kv)].slice(0, 3).join(" | "));
  console.log("  ramdisk TWRP-ish versions: " + strs(p.ramdisk, "3\\.\\d\\.\\d-[0-9]", 8).join(", "));
  const ident = strs(p.ramdisk, "twrp_[a-z0-9_.-]{3,24}", 12);
  console.log("  ramdisk device identities: " + ident.join(", "));
}

const a = res["twrp_rne_emui51.img"], b = res["stock_b186/recovery.img"], c = res["stock_b186/boot_pure.img"];
const h = (x) => crypto.createHash("sha256").update(x).digest("hex");
console.log("\n### cross-checks");
console.log("  twrp kernel == stock recovery kernel ? " + (h(a.kernel) === h(b.kernel)));
console.log("  twrp kernel == stock boot kernel     ? " + (h(a.kernel) === h(c.kernel)));
console.log("  twrp kernel bytes vs recovery/boot: " + a.kernel.length + " vs " + b.kernel.length + " / " + c.kernel.length);
for (const needle of ["hi6250", "kirin65x", "HWRNE", "RNE-AL00", "hi6250d", "LEO", "MAR", "LDN", "TREBLE"]) {
  const nb = Buffer.from(needle, "latin1");
  console.log("  kernel \"" + needle + "\": twrp=" + (a.kernel.indexOf(nb) >= 0) + " recovery=" + (b.kernel.indexOf(nb) >= 0) + " boot=" + (c.kernel.indexOf(nb) >= 0));
}
for (const needle of ["RNE", "hwHWRNE", "hi6250", "hwlte", "HW-AL00"]) {
  const nb = Buffer.from(needle, "latin1");
  console.log("  twrp ramdisk \"" + needle + "\": " + (a.ramdisk.indexOf(nb) >= 0));
}