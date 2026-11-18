const fs = require("fs");
const zlib = require("zlib");

const u32 = (b, o) => b.readUInt32LE(o);
const hx = (b, o, n) => Buffer.from(b.subarray(o, o + n)).toString("hex");
const str = (b, o, n) => b.toString("latin1", o, o + n).split("\0")[0];

function findGzipStreams(buf, limit) {
  const offs = [];
  for (let i = 0; i < Math.min(buf.length - 2, limit); i++) {
    if (buf[i] === 0x1f && buf[i + 1] === 0x8b && buf[i + 2] === 0x08) {
      let rawLen = 0;
      try { rawLen = zlib.gunzipSync(buf.subarray(i), { finishFlush: zlib.constants.ZLIB_FINISH }).length; } catch (e) { try { rawLen = zlib.gunzipSync(buf.subarray(i)).length; } catch (e2) {} }
      if (rawLen > 4096) { offs.push({ off: i, raw: rawLen }); if (offs.length >= 3) break; }
      i += 64;
    }
  }
  return offs;
}

function cpioNames(buf) {
  let q = 0; const names = []; let sizes = [];
  while (q + 110 < buf.length) {
    const magic = buf.toString("latin1", q, q + 6);
    if (magic !== "070701" && magic !== "070702") {
      const nxt = buf.indexOf("070701", q);
      if (nxt < 0 || nxt - q > 8) break;
      q = nxt;
    }
    const hex = (o, n) => parseInt(buf.toString("latin1", q + o, q + o + n), 16);
    const mode = hex(12, 8), filesize = hex(54, 8), namesize = hex(94, 8);
    if (!(namesize > 0 && namesize < 4096) || filesize > buf.length) break;
    const name = buf.toString("latin1", q + 110, q + 110 + namesize - 1);
    names.push({ name, size: filesize, dir: !!(mode & 0x4000), exec: (mode & 0x3f) >= 0x49 });
    const dataStart = Math.ceil((q + 110 + namesize) / 4) * 4;
    q = dataStart + Math.ceil(filesize / 4) * 4;
    if (name === "TRAILER!!!") break;
    if (names.length > 200000) break;
  }
  return names;
}

for (const file of process.argv.slice(2)) {
  const f = fs.readFileSync(file);
  console.log("\n########## " + file + " bytes=" + f.length);
  console.log("raw u32 table: " + [0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60, 64, 68, 72, 76, 80].map(o => o + ":" + u32(f, o)).join(" "));
  console.log("bytes0-15=" + hx(f, 0, 16) + "  name@8=" + JSON.stringify(str(f, 8, 16)));
  const gs = findGzipStreams(f, Math.min(f.length, 60000));
  console.log("gzip streams found in first 60KB: " + JSON.stringify(gs));

  const arm64 = [];
  for (let o = 0; o < Math.min(f.length - 0x40, 200000); o += 512) {
    if (u32(f, o + 0x38) === 0x14218820) arm64.push("0x" + o.toString(16));
  }
  console.log("arm64 Image headers (magic 0x14218820 @+0x38) in first 200KB: " + (arm64.join(",") || "none"));

  for (const g of gs.slice(0, 1)) {
    let raw;
    try { raw = zlib.gunzipSync(f.subarray(g.off)); } catch (e) { console.log("  gunzip failed at " + g.off + ": " + e.message); continue; }
    console.log("  stream@0x" + g.off.toString(16) + " first16=" + Buffer.from(raw.subarray(0, 16)).toString("hex") + " ascii=" + Buffer.from(raw.subarray(0, 8)).toString("latin1"));
    const list = cpioNames(raw);
    if (!list.length) { console.log("  not a cpio; head ascii=" + Buffer.from(raw.subarray(0, 32)).toString("latin1").replace(/[^\x20-\x7e]/g, ".")); continue; }
    const files = list.filter(e => !e.dir);
    console.log("  cpio entries=" + list.length + " files=" + files.length + " uncompressed=" + raw.length);
    const interesting = files.filter(e => /(twrp|recovery|init|fstab|minui|his|huawei|bootable|update|rescue|toolbox|toybox|busybox|libcw|utar|magisk|screen)/i.test(e.name)).map(e => e.name + (e.exec ? "(x)" : ""));
    console.log("  notable: " + interesting.slice(0, 45).join(", "));
    const initrc = files.find(e => e.name === "init.rc" || e.name.endsWith("/init.rc"));
    if (initrc) {
      const idx = raw.indexOf(Buffer.from("070701")) ;
      console.log("  has init.rc: " + initrc.name + " size=" + initrc.size);
    }
    const fstab = files.find(e => /fstab/i.test(e.name));
    if (fstab) {
      let p = 0;
      // locate fstab contents by walking again
      let q = 0;
      while (q < raw.length) {
        const magic = raw.toString("latin1", q, q + 6);
        if (magic !== "070701" && magic !== "070702") break;
        const hex = (o, n) => parseInt(raw.toString("latin1", q + o, q + o + n), 16);
        const filesize = hex(54, 8), namesize = hex(94, 8);
        const name = raw.toString("latin1", q + 110, q + 110 + namesize - 1);
        const dataStart = Math.ceil((q + 110 + namesize) / 4) * 4;
        if (/fstab/i.test(name)) {
          console.log("  " + name + " content:\n" + Buffer.from(raw.subarray(dataStart, dataStart + filesize)).toString("utf8").split("\n").slice(0, 22).map(s => "      " + s).join("\n"));
          break;
        }
        q = dataStart + Math.ceil(filesize / 4) * 4;
        if (name === "TRAILER!!!") break;
        p++;
      }
    }
  }
}