// Copy dd_set/ onto the FAT32 SD card and prove the copy byte-for-byte while it happens.
// Every payload is hashed on the way out of the PC and back off the card; the device re-hashes
// before it writes, so a corrupt copy can never reach eMMC unnoticed.
// usage: node tools/stage_card.js [F:/emui8_dd]
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const CARD = (process.argv[2] || "F:/emui8_dd").replace(/[\\/]+$/, "");
const SRC = "dd_set";
const SP = 512;
const HEAD = 64 * 1024;

function parseTable(file) {
  const b = fs.readFileSync(file);
  const H = b.subarray(0x200, 0x208).toString("latin1") === "EFI PART" ? 0x200 : b.indexOf("EFI PART", 0, "latin1");
  const count = b.readUInt32LE(H + 0x50), esz = b.readUInt32LE(H + 0x54);
  const base = Number(b.readBigUInt64LE(H + 0x48)) * SP;
  const map = new Map();
  for (let i = 0; i < count; i++) {
    const o = base + i * esz;
    if (o + esz > b.length) break;
    const raw = b.subarray(o + 0x38, o + 0x38 + 72);
    let n = "";
    for (let c = 0; c < 72; c += 2) { const ch = raw.readUInt16LE(c); if (!ch) break; n += String.fromCharCode(ch); }
    if (n) map.set(n, { first: Number(b.readBigUInt64LE(o + 0x20)), last: Number(b.readBigUInt64LE(o + 0x28)) });
  }
  return map;
}

const sha256File = (f) => {
  const h = crypto.createHash("sha256");
  const fd = fs.openSync(f, "r");
  const buf = Buffer.alloc(1 << 20);
  for (let off = 0; ; off += buf.length) {
    const n = fs.readSync(fd, buf, 0, buf.length, off);
    if (!n) break;
    h.update(buf.subarray(0, n));
  }
  fs.closeSync(fd);
  return h.digest("hex");
};

const sha256Range = (f, start, len) => {
  const h = crypto.createHash("sha256");
  const fd = fs.openSync(f, "r");
  const buf = Buffer.alloc(1 << 20);
  let left = len;
  while (left > 0) {
    const n = fs.readSync(fd, buf, 0, Math.min(buf.length, left), start + (len - left));
    if (!n) break;
    h.update(buf.subarray(0, n));
    left -= n;
  }
  fs.closeSync(fd);
  return h.digest("hex");
};

const live = parseTable("backups/gpt_primary_current.img");
const man = JSON.parse(fs.readFileSync(path.join(SRC, "manifest.json"), "utf8"));
const plan = fs.readFileSync(path.join(SRC, "plan.txt"), "utf8");
const fat = fs.statfsSync(path.parse(CARD).root || CARD);
const free = fat.bsize * fat.bavail;

console.log(`card ${CARD}: ${(free / 1024 / 1024 / 1024).toFixed(1)} GB free, ${man.filter((e) => e.file).length} payloads to copy`);
const need = man.reduce((a, e) => a + (e.file ? fs.statSync(path.join(SRC, `${e.name}.img`)).size : 0), 0);
if (need > free) { console.error(`need ${(need / 1e9).toFixed(1)} GB, card has ${(free / 1e9).toFixed(1)} GB`); process.exit(1); }

for (const d of ["", "imgs", "refs", "out"]) fs.mkdirSync(path.join(CARD, d), { recursive: true });

// the convention probe: live partition head vs the B186 package image, whole and stripped.
// recovery is deliberately absent - we overwrite it with TWRP before any of this runs.
const refs = [];
for (const n of ["recovery2", "teeos", "fw_hifi", "boot"]) {
  refs.push([`${n}_full_head.bin`, `rollback_b186/${n}.img`, 0]);
  refs.push([`${n}_strip_head.bin`, `rollback_b186/${n}.img`, 4096]);
}
for (const [dst, src, off] of refs) {
  const s = path.join(SRC, "..", src);
  if (fs.statSync(s).size < off + HEAD) { console.error(`${src} too short for a ${HEAD} B head at ${off}`); process.exit(1); }
  const fd = fs.openSync(s, "r");
  const b = Buffer.alloc(HEAD);
  fs.readSync(fd, b, 0, HEAD, off);
  fs.closeSync(fd);
  const out = path.join(CARD, "refs", dst);
  fs.rmSync(out, { force: true });
  fs.writeFileSync(out, b);
  const want = sha256Range(s, off, HEAD), got = sha256File(out);
  if (want !== got) { console.error(`ref ${dst} mis-copied`); process.exit(1); }
}
console.log(`refs: ${refs.length} head files, all byte-checked`);

fs.writeFileSync(path.join(CARD, "run.sh"), fs.readFileSync("tools/emui8_run.sh"));
fs.writeFileSync(path.join(CARD, "plan.txt"), plan);
fs.writeFileSync(path.join(CARD, "manifest.json"), fs.readFileSync(path.join(SRC, "manifest.json")));

const fb = live.get("fastboot");
const params = [
  `# generated ${new Date().toISOString()} by tools/stage_card.js - do not hand edit`,
  `PLAN_SHA=${sha256File(path.join(CARD, "plan.txt"))}`,
  `LIVE_GPT_SHA=${sha256File("backups/gpt_primary_current.img")}`,
  `OLD_BOOT_LBA=${live.get("boot").first}`,
  `OLD_RECOVERY_LBA=${live.get("recovery").first}`,
  `OLD_RECOVERY2_LBA=${live.get("recovery2").first}`,
  `OLD_TEEOS_LBA=${live.get("teeos").first}`,
  `OLD_FW_HIFI_LBA=${live.get("fw_hifi").first}`,
  `OLD_FASTBOOT_LBA=${fb.first}`,
  `OLD_FASTBOOT_COUNT=${fb.last - fb.first + 1}`,
].join("\n") + "\n";
fs.writeFileSync(path.join(CARD, "params.sh"), params);
console.log(params.replace(/\n/g, "\n  "));

let done = 0;
for (const e of man.filter((r) => r.file)) {
  const src = path.join(SRC, `${e.name}.img`);
  const dst = path.join(CARD, "imgs", `${e.name}.img`);
  if (fs.existsSync(dst)) {
    if (sha256File(dst) === e.sha256) { done += e.size; console.log(`  same ${e.name.padEnd(20)} ${(e.size / 1048576).toFixed(0).padStart(5)} MB  already on the card`); continue; }
    fs.rmSync(dst);
  }
  const hi = crypto.createHash("sha256"), ho = crypto.createHash("sha256");
  const fi = fs.openSync(src, "r"), fo = fs.openSync(dst, "w");
  const buf = Buffer.alloc(1 << 21);
  for (let off = 0; ; off += buf.length) {
    const n = fs.readSync(fi, buf, 0, buf.length, off);
    if (!n) break;
    hi.update(buf.subarray(0, n));
    fs.writeSync(fo, buf, 0, n);
    ho.update(buf.subarray(0, n));
  }
  fs.closeSync(fi);
  fs.closeSync(fo);
  const a = hi.digest("hex"), b = ho.digest("hex");
  if (a !== e.sha256) { console.error(`${e.name}: dd_set hash drifted (${a} != manifest ${e.sha256})`); process.exit(1); }
  if (a !== b) { console.error(`${e.name}: card copy hash ${b} != ${a}`); process.exit(1); }
  done += e.size;
  console.log(`  ok ${e.name.padEnd(20)} ${(e.size / 1048576).toFixed(0).padStart(5)} MB  ${a.slice(0, 16)}`);
}
const st = fs.statSync(path.join(CARD, "plan.txt"));
console.log(`\nstaged ${(done / 1024 / 1024 / 1024).toFixed(2)} GB into ${CARD}\\imgs (plan ${st.size} B)`);
console.log("in TWRP:  sh /external_sd/emui8_dd/run.sh preflight");