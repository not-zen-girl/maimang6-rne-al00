// Read-only convention probe. Dumps partition heads off the phone into heads_live/ and compares each
// against the B186 package image, whole and with the 4096 B entry prefix removed.
// recovery is useless as evidence here (we flashed TWRP into it); recovery2 is the same image class
// and has never been touched. Also pulls the 4 MB loader partition so xloader's offset can be found
// offline instead of guessed.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");

const ADB = "platform-tools/adb.exe";
const SERIAL = process.argv[2] || "68U5T18328012368";
const SP = 512, HEAD = 65536, OUT = "heads_live";
const SPARSE = 0xed26ff3a;
const names = ["recovery2", "teeos", "trustfirmware", "sensorhub", "fw_lpm3", "fw_hifi", "dts", "modem_fw", "boot"];

const adb = (args, opt = {}) =>
  execFileSync(ADB, ["-s", SERIAL, ...args], { encoding: "buffer", maxBuffer: 1 << 28, ...opt }).toString("utf8");

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

const head = (buf, off, len) => {
  const h = crypto.createHash("sha256");
  h.update(buf.subarray(off, off + len));
  return h.digest("hex");
};
const sha = (b) => crypto.createHash("sha256").update(b).digest("hex");

fs.mkdirSync(OUT, { recursive: true });
const live = parseTable("backups/gpt_primary_current.img");
console.log(`live  ${adb(["shell", "echo ok"]).trim()}   table ${live.size} partitions\n`);

const rows = [];
for (const n of [...names, "fastboot"]) {
  const p = live.get(n);
  if (!p) { console.log(`${n}: not in the live table`); continue; }
  const sectors = n === "fastboot" ? p.last - p.first + 1 : HEAD / SP;
  const remote = `/external_sd/emui8_dd/out/h_${n}.bin`;
  adb(["shell", `dd if=/dev/block/mmcblk0 of=${remote} bs=${SP} skip=${p.first} count=${sectors} 2>/dev/null`]);
  const local = path.join(OUT, `${n}.bin`);
  fs.rmSync(local, { force: true });
  adb(["pull", remote, local]);
  fs.rmSync(remote, { force: true });
  const got = fs.readFileSync(local);
  rows.push({ n, first: p.first, bytes: got, want: sectors * SP });
  console.log(`  pulled ${n.padEnd(15)} LBA ${String(p.first).padStart(9)}  ${got.length} B`);
}

console.log("\npartition        live head ==                       live[0:16]");
let verbatim = 0, stripped = 0, neither = 0;
for (const r of rows) {
  if (r.n === "fastboot") continue;
  const ref = path.join("rollback_b186", `${r.n}.img`);
  if (!fs.existsSync(ref)) { console.log(`${r.n.padEnd(16)} no reference image`); continue; }
  const rb = fs.readFileSync(ref);
  const isSparse = rb.readUInt32LE(0) === SPARSE;
  const a = head(rb, 0, HEAD), b = head(rb, 4096, HEAD), g = sha(r.bytes.subarray(0, HEAD));
  const verdict = isSparse ? "ref is sparse, cannot compare heads" : g === a ? "PACKAGE VERBATIM (prefix included)" : g === b ? "PACKAGE STRIPPED (4096 removed)" : "neither";
  if (!isSparse) { if (g === a) verbatim++; else if (g === b) stripped++; else neither++; }
  console.log(`${r.n.padEnd(16)} ${verdict.padEnd(38)} ${r.bytes.subarray(0, 16).toString("hex")}`);
}
console.log(`\nverbatim ${verbatim}   stripped ${stripped}   neither ${neither}`);

// where do xloader and fastboot sit inside the loader partition?
const fb = rows.find((r) => r.n === "fastboot");
if (fb) {
  console.log(`\n-- ${fb.bytes.length} B loader partition --`);
  for (const key of ["xloader", "fastboot"]) {
    const rb = fs.readFileSync(path.join("rollback_b186", `${key}.img`));
    for (const [mode, off] of [["verbatim", 0], ["stripped", 4096]]) {
      const needle = rb.subarray(off, off + 64);
      const idx = fb.bytes.indexOf(needle);
      if (idx >= 0) console.log(`  ${key.padEnd(9)} ${mode.padEnd(9)} found at partition offset ${idx} (0x${idx.toString(16)})`);
    }
  }
  const nz = [];
  for (let o = 0; o < fb.bytes.length; o += SP) if (fb.bytes.subarray(o, o + SP).some((x) => x)) { nz.push(o); if (nz.length === 1) break; }
  const lastUsed = (() => { for (let o = fb.bytes.length - SP; o >= 0; o -= SP) if (fb.bytes.subarray(o, o + SP).some((x) => x)) return o; return -1; })();
  console.log(`  first non-zero sector ${nz[0] ?? -1}, last non-zero sector ${lastUsed} (${((lastUsed + SP) / 1024 / 1024).toFixed(2)} MB used of ${(fb.bytes.length / 1048576).toFixed(0)} MB)`);
  console.log(`  head sha256 ${sha(fb.bytes.subarray(0, HEAD))}`);
}