// Sync dd_set/ onto the card *through the phone* (the card is in the handset, not a reader).
// Pulls the manifest the card currently carries and pushes only what differs, then re-hashes every
// pushed file on the device. run.sh / plan.txt / params.sh / refs always go over. `verify` in the
// recovery script re-hashes the whole set before anything is written, so a stale file cannot slip
// into a dd.
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");

const ADB = "platform-tools/adb.exe";
const SERIAL = process.env.SERIAL || "68U5T18328012368";
const CARD = "/external_sd/emui8_dd";
const SP = 512;

const adb = (args, opt = {}) => execFileSync(ADB, ["-s", SERIAL, ...args], { encoding: "buffer", maxBuffer: 1 << 28, ...opt });
const dev = (cmd, tolerate = false) => {
  try {
    return execFileSync(ADB, ["-s", SERIAL, "shell", cmd], { encoding: "buffer", maxBuffer: 1 << 28 }).toString("utf8").replace(/\r/g, "").trim();
  } catch (e) {
    if (tolerate) return "";
    throw e;
  }
};
const sha256File = (f) => {
  const h = crypto.createHash("sha256");
  const fd = fs.openSync(f, "r");
  const buf = Buffer.alloc(1 << 21);
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

console.log("phone:", dev("echo ok"));

// what the card thinks it has right now
let old = [];
try {
  fs.rmSync("dd_set/card_manifest.json", { force: true });
  adb(["pull", `${CARD}/manifest.json`, "dd_set/card_manifest.json"]);
  old = JSON.parse(fs.readFileSync("dd_set/card_manifest.json", "utf8"));
} catch { console.log("card manifest absent - pushing every payload"); }
const oldSha = new Map(old.filter((e) => e.file).map((e) => [e.name, e.sha256]));
const man = JSON.parse(fs.readFileSync("dd_set/manifest.json", "utf8"));

dev(`mkdir -p ${CARD}/imgs ${CARD}/refs ${CARD}/out`);
const push = (local, remote, want) => {
  const got0 = want ? dev(`sha256sum ${remote} 2>/dev/null`, true).split(" ")[0] : "";
  if (got0 === want) { console.log(`  ok(same) ${remote}`); return; }
  const line = adb(["push", local, remote]).toString("utf8").replace(/\r/g, "");
  if (/error|failed/.test(line)) throw new Error(`push failed: ${line.trim()}`);
  const got = dev(`sha256sum ${remote}`).split(" ")[0];
  if (want && got !== want) throw new Error(`${remote} landed as ${got}, wanted ${want}`);
  console.log(`  pushed ${remote}  ${got.slice(0, 16)}`);
};

// metadata + the convention references
const live = parseTable("backups/gpt_primary_current.img");
const refs = [];
for (const n of ["recovery2", "teeos", "fw_hifi", "boot"]) for (const [mode, off] of [["full", 0], ["strip", 4096]])
  refs.push([`${n}_${mode}_head.bin`, `rollback_b186/${n}.img`, off]);
for (const [dst, src, off] of refs) {
  const tmp = path.join("dd_set", dst);
  const fd = fs.openSync(src, "r");
  const b = Buffer.alloc(64 * 1024);
  fs.readSync(fd, b, 0, b.length, off);
  fs.closeSync(fd);
  fs.writeFileSync(tmp, b);
  push(tmp, `${CARD}/refs/${dst}`, sha256Range(src, off, 64 * 1024));
  fs.rmSync(tmp, { force: true });
}

fs.writeFileSync("dd_set/params.sh", [
  `# generated ${new Date().toISOString()} by tools/push_to_phone.js - do not hand edit`,
  `PLAN_SHA=${sha256File("dd_set/plan.txt")}`,
  `LIVE_GPT_SHA=${sha256File("backups/gpt_primary_current.img")}`,
  `OLD_BOOT_LBA=${live.get("boot").first}`,
  `OLD_RECOVERY_LBA=${live.get("recovery").first}`,
  `OLD_RECOVERY2_LBA=${live.get("recovery2").first}`,
  `OLD_TEEOS_LBA=${live.get("teeos").first}`,
  `OLD_FW_HIFI_LBA=${live.get("fw_hifi").first}`,
  `OLD_FASTBOOT_LBA=${live.get("fastboot").first}`,
  `OLD_FASTBOOT_COUNT=${live.get("fastboot").last - live.get("fastboot").first + 1}`,
].join("\n") + "\n");

push("dd_set/plan.txt", `${CARD}/plan.txt`, sha256File("dd_set/plan.txt"));
push("dd_set/params.sh", `${CARD}/params.sh`, null);
push("tools/emui8_run.sh", `${CARD}/run.sh`, sha256File("tools/emui8_run.sh"));
push("dd_set/manifest.json", `${CARD}/manifest.json`, null);

let pushed = 0, skipped = 0;
for (const e of man.filter((r) => r.file)) {
  if (oldSha.get(e.name) === e.sha256) { skipped++; continue; }
  push(path.join("dd_set", `${e.name}.img`), `${CARD}/imgs/${e.name}.img`, e.sha256);
  pushed += e.size;
}
console.log(`\npayloads: ${pushed ? (pushed / 1048576).toFixed(0) + " MB pushed" : "none needed"}, ${skipped} already matching on the card`);
console.log("next:  sh /external_sd/emui8_dd/run.sh preflight");