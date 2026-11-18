const fs = require("fs");
const zlib = require("zlib");

const u32 = (b, o) => b.readUInt32LE(o);
const al = (n, p) => Math.ceil(n / p) * p;
const s = (b, o, n) => b.toString("latin1", o, o + n).split("\0")[0];

function decomp(buf) {
  if (buf[0] === 0x1f && buf[1] === 0x8b) return { kind: "gzip", out: zlib.gunzipSync(buf, { finishFlush: 4 }) };
  if (buf.toString("latin1", 4, 8) === "0422" ) return { kind: "?", out: buf };
  return { kind: "raw", out: buf };
}

function cpio(buf) {
  const list = []; let q = 0;
  while (q + 110 < buf.length) {
    const mg = buf.toString("latin1", q, q + 6);
    if (mg !== "070701" && mg !== "070702") break;
    const hex = (o, n) => parseInt(buf.toString("latin1", q + o, q + o + n), 16);
    const mode = hex(12, 8), filesize = hex(54, 8), namesize = hex(94, 8);
    if (namesize < 1 || namesize > 4096 || filesize > buf.length) break;
    const name = buf.toString("latin1", q + 110, q + 110 + namesize - 1);
    const dataStart = al(q + 110 + namesize, 4);
    list.push({ name, size: filesize, mode, dir: !!(mode & 0x4000), exec: (mode & 0x3f) >= 0x49, dataStart });
    q = dataStart + al(filesize, 4);
    if (name === "TRAILER!!!") break;
  }
  return list;
}

for (const file of process.argv.slice(2)) {
  const f = fs.readFileSync(file);
  const kernel = u32(f, 8), ramdisk = u32(f, 16), second = u32(f, 24), dtb = u32(f, 40) && 0;
  const page = u32(f, 36) || 2048;
  const hver = u32(f, 40);
  const hdrPages = u32(f, 68) && 0;
  console.log("\n########## " + file + " bytes=" + f.length);
  console.log("  magic=" + s(f, 0, 8) + " kernel=" + kernel + " ramdisk=" + ramdisk + " second=" + second + " pagesize=" + page + " header_version=" + hver);
  console.log("  name=\"" + s(f, 48, 16) + "\"  cmdline=\"" + s(f, 64, 224).slice(0, 200) + "\"");

  const koff = al(Math.max(hver >= 1 ? 0 : 1, 1) * page, page) || page;
  const kraw = f.subarray(koff, koff + al(kernel, page));
  const rdOff = koff + al(kernel, page);
  const rraw = f.subarray(rdOff, rdOff + al(ramdisk, page));

  const kd = decomp(kraw);
  console.log("  kernel: stored=" + kernel + " kind=" + kd.kind + " decompressed=" + kd.out.length);
  if (kd.out.length > 4096) {
    const armMagic = u32(kd.out, 0x38);
    console.log("    arm64 Image magic@0x38 = 0x" + armMagic.toString(16) + (armMagic === 0x14218820 ? "  (valid arm64 kernel Image)" : "  (not an arm64 Image header)"));
    const i = kd.out.indexOf("Linux version");
    if (i >= 0) console.log("    " + kd.out.toString("latin1", i, i + 90).replace(/[^\x20-\x7e]/g, "."));
    for (const needle of ["4.1.18-g86ace34", "hi6250", "kirin65x", "HWRNE", "RNE-AL00", "q2s"]) {
      const j = kd.out.indexOf(Buffer.from(needle, "latin1"));
      if (j >= 0) console.log("    kernel contains \"" + needle + "\" @0x" + j.toString(16));
    }
  }

  const rd = decomp(rraw);
  console.log("  ramdisk: stored=" + ramdisk + " kind=" + rd.kind + " decompressed=" + rd.out.length + " offset=0x" + rdOff.toString(16));
  const list = cpio(rd.out);
  console.log("  ramdisk cpio entries=" + list.length);
  const files = list.filter(e => !e.dir);
  const notable = files.filter(e => /(twrp|minui|crecovery|recovery|fstab|init\.rc|his|huawei|dload|toolbox|busybox|magisk|screen|omni)/i.test(e.name));
  console.log("  notable files: " + notable.slice(0, 40).map(e => e.name + (e.exec ? "(x)" : "")).join(", "));
  for (const e of list) {
    if (/fstab/i.test(e.name)) {
      const txt = Buffer.from(rd.out.subarray(e.dataStart, e.dataStart + e.size)).toString("utf8");
      console.log("  === " + e.name + " ===\n" + txt.split("\n").slice(0, 26).map(l => "    " + l).join("\n"));
    }
    if (/(twrp\.defaults|etc\/twrp|version\.tmp|etc\/recovery\.rc)/.test(e.name) && e.size < 4000) {
      const txt = Buffer.from(rd.out.subarray(e.dataStart, e.dataStart + e.size)).toString("utf8");
      console.log("  === " + e.name + " ===\n" + txt.split("\n").slice(0, 12).map(l => "    " + l).join("\n"));
    }
  }
}