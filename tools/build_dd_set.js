// Build the dd payload for the EMUI 8 (B379) hand-written upgrade.
// - un-sparses every Android sparse image into dd_set/ (a sparse file written raw is garbage)
// - resolves each image's LBA target from the *completed* EMUI8 GPT
// - hard-fails if a protected partition moved, if a payload would spill past its partition,
//   or if a filesystem image is not raw ext4
// - reports which writes land on the current boot/recovery LBAs (that is what ends TWRP)
// usage: node tools/probe_heads.js   (reads the live partition heads)  then  node tools/build_dd_set.js
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");

const SRC = "emui8_b379";
const OUT = "dd_set";
const NEW_GPT = "backups/efi_emui8_fixed.img";
const LIVE_GPT = "backups/gpt_primary_current.img";
const SPARSE_MAGIC = 0xed26ff3a;
const SP = 512;

const argv = process.argv.slice(2);
const EVIDENCE = "heads_live";

// never written, and must not move between the two tables
const PROTECTED = [
  "nvme", "oeminfo", "modemnvm_factory", "modemnvm_backup", "modemnvm_img",
  "modemnvm_system", "secure_storage", "persist", "modem_secure",
  "vrl", "vrl_backup", "splash2", "frp", "rrecord", "bootfail_info", "dfx",
  "hisitest0", "hisitest1", "hisitest2",
];
// Huawei spare partitions: never written, but the official new table may re-pack them
const SPARES = ["reserved2", "reserved3", "reserved4", "reserved5", "reserved8", "reserved9"];
// in the package image table and written by the official updater too, so we match it
const APPROVED_EXCEPTION = ["modemnvm_update"];

// Neither table has an xloader partition: xloader.img is written to the eMMC HW boot areas
// (mmcblk0boot0/boot1, which never appear in a GPT) and no offset there is derivable from the
// package, so it stays as the working EMUI5 build. The second-stage loader is different - it lives
// in the `fastboot` partition, which both tables agree on, and *must* become the EMUI8 build
// because the EMUI5 one resolves the partition name `boot`, and that name is gone after the flip.
// probe_heads.js proved byte-for-byte that the partition holds fastboot.img without its 4096 B
// entry header, at offset 0, so the payload is the de-headed image at the partition's own LBA.
const SKIP = { xloader: "written to mmcblk0boot0/1 by dload, not in any GPT - left untouched" };

function magicAt(b, off) {
  if (off + 8 > b.length) return "";
  if (off === 0 && b.readUInt32LE(0) === SPARSE_MAGIC) return "sparse";
  if (off === 0 && b.readUInt16LE(0x438) === 0xef53) return "ext4";
  if (off === 0 && b.readUInt32LE(0x400) === 0xf2f52010) return "f2fs";
  const s = b.subarray(off, off + 8).toString("latin1");
  if (s === "ANDROID!") return "ANDROID!";
  for (const m of ["AVB0", "HSDT", "HIF:", "nv"]) if (s.startsWith(m)) return m;
  if (b.readUInt32LE(off) === 0x5a5aa5a5) return "a5a55a5a";
  return "";
}

// what the phone itself says: compare a live partition head against the B186 package image, whole
// and with the entry header removed. heads_live/ comes from tools/probe_heads.js.
function twinVerdict(name) {
  const liveFile = path.join(EVIDENCE, `${name}.bin`), refFile = path.join("rollback_b186", `${name}.img`);
  if (!fs.existsSync(liveFile) || !fs.existsSync(refFile)) return "";
  const l = fs.readFileSync(liveFile);
  const refLen = fs.statSync(refFile).size;
  for (const [off, verdict] of [[0, "verbatim"], [4096, "stripped"]]) {
    const n = Math.min(l.length, refLen - off);
    if (n < 0x10000) continue; // shorter than 64 KB of comparison is not evidence
    const fd = fs.openSync(refFile, "r");
    const b = Buffer.alloc(n);
    const got = fs.readSync(fd, b, 0, n, off);
    fs.closeSync(fd);
    if (got === n && b.equals(l.subarray(0, n))) return verdict;
  }
  return "neither";
}

// Huawei's dload pads a 4096 B entry header in front of most images and the partition holds the
// image without it. Each decision below is justified by the payload's own magic or by a byte-level
// match against a partition this device held before we touched anything - undecidable means abort.
function stripFor(name, src) {
  const fd = fs.openSync(src, "r");
  const b = Buffer.alloc(0x2000);
  fs.readSync(fd, b, 0, b.length, 0);
  fs.closeSync(fd);
  const at0 = magicAt(b, 0), at4 = magicAt(b, 4096);
  const twin = twinVerdict(name);
  if (twin === "neither") problems.push(`${name}: the live partition matches neither layout - stop`);
  const byMagic = at0 ? 0 : at4 ? 4096 : -1;
  const byTwin = twin ? (twin === "stripped" ? 4096 : 0) : -1;
  if (byMagic >= 0 && byTwin >= 0 && byMagic !== byTwin)
    problems.push(`${name}: magic at ${byMagic ? 4096 : 0} disagrees with the live partition (${byTwin}) - stop`);
  const strip = byMagic >= 0 ? byMagic : byTwin;
  if (strip < 0) problems.push(`${name}: no recognised magic and no live twin - refusing to guess the entry header`);
  return { strip: strip < 0 ? 0 : strip, why: at0 ? `${at0}@0` : at4 ? `${at4}@4096` : twin === "stripped" ? "live=stripped" : twin === "verbatim" ? "live=verbatim" : "?" };
}

function copySkip(src, dst, skip) {
  const fi = fs.openSync(src, "r"), fo = fs.openSync(dst, "w");
  const buf = Buffer.alloc(1 << 21);
  for (let off = skip; ; ) {
    const n = fs.readSync(fi, buf, 0, buf.length, off);
    if (!n) break;
    fs.writeSync(fo, buf, 0, n);
    off += n;
  }
  fs.closeSync(fi);
  fs.closeSync(fo);
}
const FILESYSTEMS = ["cache", "system", "vendor", "product", "odm", "cust", "version", "preas", "preavs"];
const BOOTIMGS = ["kernel", "ramdisk", "recovery_ramdisk", "recovery_vendor", "erecovery_kernel", "erecovery_ramdisk", "erecovery_vendor"];

const ORDER = [
  "fw_lpm3", "teeos", "trustfirmware", "sensorhub", "fw_hifi",
  "modemnvm_update", "modem_fw", "dts", "vbmeta", "recovery_vbmeta", "erecovery_vbmeta",
  "system", "vendor", "product", "odm", "version", "cust", "preas", "preavs",
  "cache", "kernel", "ramdisk", "recovery_ramdisk", "recovery_vendor",
  "erecovery_kernel", "erecovery_ramdisk", "erecovery_vendor",
];
// phase 2: the second-stage loader, written after every filesystem payload has landed
const ORDER2 = ["fastboot"];

function parseTable(file) {
  const b = fs.readFileSync(file);
  const H = b.subarray(0x200, 0x208).toString("latin1") === "EFI PART" ? 0x200 : b.indexOf("EFI PART", 0, "latin1");
  if (H < 0) throw new Error(`${file}: no EFI PART signature`);
  const count = b.readUInt32LE(H + 0x50);
  const esz = b.readUInt32LE(H + 0x54);
  const base = Number(b.readBigUInt64LE(H + 0x48)) * SP;
  const map = new Map();
  for (let i = 0; i < count; i++) {
    const o = base + i * esz;
    if (o + esz > b.length) break;
    const first = Number(b.readBigUInt64LE(o + 0x20));
    const last = Number(b.readBigUInt64LE(o + 0x28));
    if (!first && !last) continue;
    const raw = b.subarray(o + 0x38, o + 0x38 + 72);
    let name = "";
    for (let c = 0; c < 72; c += 2) {
      const ch = raw.readUInt16LE(c);
      if (!ch) break;
      name += String.fromCharCode(ch);
    }
    if (name) map.set(name, { first, last });
  }
  return { buf: b, map, entries: map.size, esz };
}

function sha256File(f) {
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
}

function head4k(f) {
  const fd = fs.openSync(f, "r");
  const b = Buffer.alloc(0x2000);
  const n = fs.readSync(fd, b, 0, 0x2000, 0);
  fs.closeSync(fd);
  return b.subarray(0, n);
}

function formatOf(f) {
  const h = head4k(f);
  const u32 = (o) => (o + 4 <= h.length ? h.readUInt32LE(o) : 0);
  const u16 = (o) => (o + 2 <= h.length ? h.readUInt16LE(o) : 0);
  if (u32(0) === SPARSE_MAGIC) return "STILL-SPARSE";
  if (u16(0x438) === 0xef53) return "ext4"; // ext4 superblock magic is 16 bits at 1024+56
  if (u32(1024) === 0xf2f52010) return "f2fs";
  if (u32(1024) === 0xe0f5e1e2) return "erofs";
  if (h.subarray(0, 8).toString("latin1") === "ANDROID!") return "bootimg@0";
  if (h.subarray(0x1000, 0x1008).toString("latin1") === "ANDROID!") return "bootimg@0x1000";
  if (u32(0) === 0x41564230) return "avb";
  if (h.subarray(0, 6).toString("latin1") === "hs_cs_") return "f2fs";
  const zeros = h.readUInt32LE(0) === 0;
  let zeroRun = 0;
  while (zeroRun < h.length && h[zeroRun] === 0) zeroRun++;
  return zeros ? `zeros(${zeroRun} B lead)` : `raw(${h.readUInt32LE(0).toString(16)})`;
}

const live = parseTable(LIVE_GPT);
const neu = parseTable(NEW_GPT);
const problems = [];

for (const n of PROTECTED) {
  const a = live.map.get(n), c = neu.map.get(n);
  if (!a || !c) { problems.push(`protected partition missing from a table: ${n}`); continue; }
  if (a.first !== c.first || a.last !== c.last)
    problems.push(`PROTECTED PARTITION MOVED: ${n} ${a.first}..${a.last} -> ${c.first}..${c.last}`);
}
for (const n of APPROVED_EXCEPTION) {
  const a = live.map.get(n), c = neu.map.get(n);
  if (!a || !c) { problems.push(`exception partition missing from a table: ${n}`); continue; }
  if (a.first !== c.first || a.last !== c.last)
    problems.push(`${n} range differs between tables - re-check before writing it`);
}
for (const n of SPARES) {
  const a = live.map.get(n), c = neu.map.get(n);
  if (a && c && (a.first !== c.first || a.last !== c.last))
    console.log(`note: spare ${n} re-packed ${a.first}..${a.last} -> ${c.first}..${c.last} (never written)`);
}
if (problems.length) { console.error(problems.join("\n")); process.exit(1); }

const oldBoot = live.map.get("boot"), oldRec = live.map.get("recovery");
const hits = (r, x) => r.first <= x.last && r.last >= x.first;
const ownerOf = (lba) => {
  for (const [n, r] of live.map) if (lba >= r.first && lba <= r.last) return n;
  return "(free/data)";
};

fs.mkdirSync(OUT, { recursive: true });
const rows = [], manifest = [];

function add(name, phase) {
  const tgt = neu.map.get(name);
  if (!tgt) { problems.push(`${name}: not a partition in the new table`); return; }
  for (const p of PROTECTED) {
    const r = neu.map.get(p);
    if (r && hits(tgt, r)) problems.push(`${name} would overwrite protected ${p}`);
  }
  const capBytes = (tgt.last - tgt.first + 1) * SP;
  const src = path.join(SRC, `${name}.img`);
  if (!fs.existsSync(src)) { problems.push(`missing source image ${src}`); return; }
  const dst = path.join(OUT, `${name}.img`);
  let sparse = false, strip = 0, why = "";
  if (head4k(src).readUInt32LE(0) === SPARSE_MAGIC) {
    sparse = true;
    why = "sparse@0";
    console.log(execFileSync(process.execPath, ["tools/simg2img.js", src, dst], { stdio: "pipe" }).toString().trim());
  } else {
    ({ strip, why } = stripFor(name, src));
    if (strip) copySkip(src, dst, strip);
    else fs.copyFileSync(src, dst);
  }
  let size = fs.statSync(dst).size;
  if (size % SP) {
    fs.appendFileSync(dst, Buffer.alloc(SP - (size % SP))); // whole sectors, so read-back hashing matches
    size = fs.statSync(dst).size;
  }
  const fmt = formatOf(dst);
  if (FILESYSTEMS.includes(name) && fmt !== "ext4")
    problems.push(`${name}: payload is ${fmt}, not raw ext4 - dd would write an unmountable partition`);
  if (BOOTIMGS.includes(name) && !fmt.startsWith("bootimg"))
    problems.push(`${name}: payload is ${fmt}, expected a boot image`);
  if (size > capBytes) {
    problems.push(`${name}: payload ${size} B exceeds partition ${capBytes} B (would spill into the next partition)`);
    return;
  }
  const sectors = size / SP;
  const span = { first: tgt.first, last: tgt.first + sectors - 1 };
  const overlap = [];
  if (hits(span, oldBoot)) overlap.push("boot");
  if (hits(span, oldRec)) overlap.push("recovery");
  rows.push({
    name, phase, first: tgt.first, sectors, size, capBytes, sparse, fmt, why, strip,
    exact: size === capBytes, overlap: overlap.join("+") || "-", oldOwner: ownerOf(tgt.first),
  });
  manifest.push({ name, phase, first: tgt.first, sectors, size, sha256: sha256File(dst), file: `imgs/${name}.img` });
}

for (const n of ORDER) add(n, 1);
for (const n of ORDER2) add(n, 2);
for (const [n, why] of Object.entries(SKIP))
  rows.push({ name: n, phase: "skip", first: "-", sectors: 0, size: 0, capBytes: 0, sparse: false, fmt: why, why: "-", exact: false, overlap: "-", oldOwner: "-" });

// the table flip: the whole 17408 B dump (LBA0 protective MBR + header + entries) at LBA0
{
  const dst = path.join(OUT, "efi.img");
  fs.copyFileSync(NEW_GPT, dst);
  const size = fs.statSync(dst).size;
  if (size !== 34 * SP) problems.push(`efi dump is ${size} B, expected ${34 * SP}`);
  const a = fs.readFileSync(LIVE_GPT).subarray(0, SP), b = fs.readFileSync(dst).subarray(0, SP);
  if (!a.equals(b)) problems.push("protective MBR differs from the live dump - only the table may change");
  rows.push({ name: "efi", phase: 4, first: 0, sectors: 34, size, capBytes: 34 * SP, sparse: false, fmt: "GPT", exact: true, overlap: "-", oldOwner: "LBA0-33 (GPT)" });
  manifest.push({ name: "efi", phase: 4, first: 0, sectors: 34, size, sha256: sha256File(dst), file: "imgs/efi.img" });
}

// misc first: a stale BCB must not be able to redirect the boot once the new system lands.
{
  const tgt = neu.map.get("misc");
  const bytes = 2 * 1024 * 1024;
  rows.push({ name: "misc(erase BCB)", phase: 3, first: tgt.first, sectors: bytes / SP, size: bytes, capBytes: (tgt.last - tgt.first + 1) * SP, sparse: false, fmt: "zeros", exact: false, overlap: "-", oldOwner: "misc" });
  manifest.push({ name: "misc_zero", phase: 3, first: tgt.first, sectors: bytes / SP, size: bytes, zero: true, file: "" });
}
// userdata: the package's 24 MB marker would be mounted as a 24 MB /data, so zero the head and let
// the OS format the whole 53 GB partition.
{
  const tgt = neu.map.get("userdata");
  const bytes = 8 * 1024 * 1024;
  rows.push({ name: "userdata(zero head)", phase: 3, first: tgt.first, sectors: bytes / SP, size: bytes, capBytes: (tgt.last - tgt.first + 1) * SP, sparse: false, fmt: "zeros", exact: false, overlap: "-", oldOwner: "userdata" });
  manifest.push({ name: "userdata_zero", phase: 3, first: tgt.first, sectors: bytes / SP, size: bytes, zero: true, file: "" });
}

// stable sort: phases run in order, but within a phase the ORDER above is deliberate (everything
// that does not touch the running TWRP comes first)
manifest.sort((a, b) => a.phase - b.phase);
rows.sort((a, b) => (a.phase === "-" ? -1 : Number(a.phase)) - (b.phase === "-" ? -1 : Number(b.phase)));

fs.writeFileSync(path.join(OUT, "manifest.json"), JSON.stringify(manifest, null, 1));

const pad = (s, n) => String(s).padEnd(n);
console.log(`\nlive table: ${live.entries} partitions   new table: ${neu.entries} partitions   live heads in ${EVIDENCE}/: ${fs.existsSync(EVIDENCE) ? fs.readdirSync(EVIDENCE).length : 0}`);
console.log(`old boot LBA ${oldBoot.first}..${oldBoot.last}   old recovery LBA ${oldRec.first}..${oldRec.last}\n`);
console.log(pad("partition", 20), pad("ph", 3), pad("first LBA", 10), pad("sectors", 9), pad("payload", 13), pad("capacity", 13), pad("format", 16), pad("entry header", 22), pad("old owner", 14), "hits");
for (const r of rows)
  console.log(
    pad(r.name, 20), pad(r.phase, 3), pad(r.first, 10), pad(r.sectors, 9),
    pad(r.size.toLocaleString(), 13), pad(r.capBytes.toLocaleString(), 13),
    pad(r.fmt, 16), pad(r.strip ? `-4096 (${r.why})` : r.why, 22), pad(r.oldOwner, 14), r.overlap,
  );
const total = rows.reduce((a, r) => a + r.size, 0);
const loose = rows.filter((r) => r.exact === false && r.phase < 3);
console.log(`\ntotal to write: ${(total / 1024 / 1024).toFixed(0)} MB into ${rows.length} targets`);
if (loose.length) console.log(`payload smaller than partition (stale tail survives): ${loose.map((r) => r.name).join(", ")}`);
const kills = rows.filter((r) => r.overlap !== "-");
console.log(`writes landing on old boot/recovery LBAs (these end TWRP): ${kills.map((r) => r.name).join(", ") || "none"}`);
if (problems.length) { console.log("\nPROBLEMS:\n" + problems.join("\n")); process.exit(1); }
console.log("checks passed");